//! Bidirectional Wayland clipboard synchronization over QUIC bidirectional streams.
//!
//! Uses `ext_data_control_manager_v1` (preferred) or `zwlr_data_control_manager_v1`
//! (fallback) to watch local clipboard offers and serve remote offers lazily on paste.
//! Loop prevention uses FIFO `wl_display.sync()` tracking of our own `set_selection`
//! calls. Password-manager secrets (`x-kde-passwordManagerHint` = `secret`) are never
//! forwarded.

use quinn::{Connection, RecvStream, SendStream};
use std::collections::{BTreeSet, HashMap};
use std::io;
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::fs::FileTypeExt;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot, watch, Semaphore};
use tokio::task::JoinSet;
use tokio::time::Instant;
use wayland_client::backend::WaylandError;
use wayland_client::protocol::{wl_callback, wl_registry, wl_seat};
use wayland_client::{Connection as WlConnection, Dispatch, Proxy, QueueHandle};
use wayland_protocols::ext::data_control::v1::client::{
    ext_data_control_device_v1, ext_data_control_manager_v1, ext_data_control_offer_v1,
    ext_data_control_source_v1,
};
use wayland_protocols_wlr::data_control::v1::client::{
    zwlr_data_control_device_v1, zwlr_data_control_manager_v1, zwlr_data_control_offer_v1,
    zwlr_data_control_source_v1,
};

pub const CLIP_MSG_OFFER: u8 = 1;
pub const CLIP_MSG_FETCH: u8 = 2;
pub const CLIP_OFFER_ACK: u8 = 0;
pub const CLIP_FETCH_OK: u8 = 0;
pub const CLIP_FETCH_UNAVAILABLE: u8 = 1;

pub const MAX_MIME_TYPES: usize = 64;
pub const MAX_MIME_LEN: usize = 256;
const MAX_RAW_OFFER_MIMES: usize = 256;
pub const MAX_CLIPBOARD_BYTES: usize = 32 * 1024 * 1024;
const MAX_OFFER_FRAME_BYTES: usize = 1 + 8 + 2 + MAX_MIME_TYPES * (2 + MAX_MIME_LEN);
const MAX_FETCH_REQ_BYTES: usize = 1 + 8 + 2 + MAX_MIME_LEN;
const MAX_SECRET_HINT_BYTES: usize = 64;

const CLIP_STREAM_PRIORITY: i32 = -10;
const CLIP_CONTROL_IO_TIMEOUT: Duration = Duration::from_secs(2);
const CLIP_FETCH_TIMEOUT: Duration = Duration::from_secs(15);
const CLIP_PIPE_IDLE_TIMEOUT: Duration = Duration::from_secs(5);
const SECRET_HINT_TIMEOUT: Duration = Duration::from_millis(250);
const WAYLAND_RECONNECT_BACKOFF: Duration = Duration::from_secs(2);
const CLIP_JOIN_DRAIN_BUDGET: Duration = Duration::from_millis(100);

const MAX_CONCURRENT_FETCH_SERVES: usize = 8;
const MAX_CONCURRENT_REMOTE_FETCHES: usize = 8;

const SECRET_HINT_MIME: &str = "x-kde-passwordManagerHint";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalOfferMeta {
    pub seq: u64,
    pub mimes: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct ClipboardHub {
    local_offer_rx: watch::Receiver<Option<LocalOfferMeta>>,
    cmd_tx: mpsc::UnboundedSender<HubCmd>,
    active_conn: Arc<std::sync::Mutex<Option<Connection>>>,
}

enum HubCmd {
    SetRemoteOffer {
        seq: u64,
        mimes: Vec<String>,
    },
    ReceiveLocal {
        seq: u64,
        mime: String,
        write_fd: OwnedFd,
        reply: oneshot::Sender<Result<(), &'static str>>,
    },
}

enum WaylandMsg {
    SetRemoteOffer {
        seq: u64,
        mimes: Vec<String>,
    },
    ReceiveLocal {
        seq: u64,
        mime: String,
        write_fd: OwnedFd,
        reply: oneshot::Sender<Result<(), &'static str>>,
    },
    PromoteCandidate {
        candidate_seq: u64,
        mimes: Vec<String>,
    },
    RejectCandidate {
        candidate_seq: u64,
    },
}

impl ClipboardHub {
    pub fn spawn(
        shutdown_rx: watch::Receiver<bool>,
    ) -> (Self, tokio::task::JoinHandle<()>) {
        Self::spawn_with_backend(shutdown_rx, true)
    }

    pub fn spawn_with_backend(
        mut shutdown_rx: watch::Receiver<bool>,
        connect_wayland: bool,
    ) -> (Self, tokio::task::JoinHandle<()>) {
        let (local_offer_tx, local_offer_rx) = watch::channel(None);
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<HubCmd>();
        let active_conn: Arc<std::sync::Mutex<Option<Connection>>> =
            Arc::new(std::sync::Mutex::new(None));

        let hub = Self {
            local_offer_rx,
            cmd_tx,
            active_conn: active_conn.clone(),
        };

        let conn_for_task = active_conn;
        let handle = tokio::spawn(async move {
            let mut wl_tx: Option<mpsc::UnboundedSender<WaylandMsg>> = None;
            let mut wl_handle: Option<tokio::task::JoinHandle<()>> = None;

            if connect_wayland {
                let (tx, rx) = mpsc::unbounded_channel();
                wl_tx = Some(tx.clone());
                wl_handle = Some(tokio::spawn(run_wayland_supervisor(
                    rx,
                    tx,
                    local_offer_tx,
                    conn_for_task,
                    shutdown_rx.clone(),
                )));
            }

            loop {
                tokio::select! {
                    biased;
                    _ = shutdown_rx.changed() => break,
                    cmd = cmd_rx.recv() => {
                        let Some(cmd) = cmd else { break; };
                        if let Some(tx) = &wl_tx {
                            let msg = match cmd {
                                HubCmd::SetRemoteOffer { seq, mimes } => {
                                    WaylandMsg::SetRemoteOffer { seq, mimes }
                                }
                                HubCmd::ReceiveLocal { seq, mime, write_fd, reply } => {
                                    WaylandMsg::ReceiveLocal { seq, mime, write_fd, reply }
                                }
                            };
                            let _ = tx.send(msg);
                        } else if let HubCmd::ReceiveLocal { reply, .. } = cmd {
                            let _ = reply.send(Err("wayland clipboard unavailable"));
                        }
                    }
                }
            }

            drop(wl_tx);
            if let Some(h) = wl_handle {
                let _ = tokio::time::timeout(Duration::from_millis(40), h).await;
            }
        });

        (hub, handle)
    }

    pub fn set_active_connection(&self, conn: Option<Connection>) {
        let mut guard = self.active_conn.lock().unwrap_or_else(|e| e.into_inner());
        *guard = conn;
    }

    pub fn set_remote_offer(&self, seq: u64, mimes: Vec<String>) {
        let _ = self.cmd_tx.send(HubCmd::SetRemoteOffer { seq, mimes });
    }

    pub async fn receive_local(&self, seq: u64, mime: String, write_fd: OwnedFd) -> Result<(), &'static str> {
        let (reply_tx, reply_rx) = oneshot::channel();
        if self
            .cmd_tx
            .send(HubCmd::ReceiveLocal {
                seq,
                mime,
                write_fd,
                reply: reply_tx,
            })
            .is_err()
        {
            return Err("clipboard hub closed");
        }
        match tokio::time::timeout(CLIP_CONTROL_IO_TIMEOUT, reply_rx).await {
            Ok(Ok(res)) => res,
            Ok(Err(_)) => Err("clipboard hub dropped"),
            Err(_) => Err("clipboard receive timed out"),
        }
    }

    pub fn subscribe_local_offer(&self) -> watch::Receiver<Option<LocalOfferMeta>> {
        self.local_offer_rx.clone()
    }
}

pub fn spawn_clipboard_session(
    connection: Connection,
    hub: ClipboardHub,
    cancel_rx: watch::Receiver<bool>,
) -> tokio::task::JoinHandle<()> {
    hub.set_active_connection(Some(connection.clone()));

    tokio::spawn(async move {
        let mut local_rx = hub.subscribe_local_offer();
        let mut cancel_out = cancel_rx.clone();
        let out_conn = connection.clone();

        let outbound_offers = tokio::spawn(async move {
            let initial = local_rx.borrow_and_update().clone();
            if let Some(meta) = initial {
                if send_offer(&out_conn, meta.seq, &meta.mimes).await.is_err() {
                    return;
                }
            }
            loop {
                tokio::select! {
                    biased;
                    _ = cancel_out.changed() => break,
                    changed = local_rx.changed() => {
                        if changed.is_err() {
                            break;
                        }
                        let meta = local_rx.borrow_and_update().clone();
                        if let Some(meta) = meta {
                            if send_offer(&out_conn, meta.seq, &meta.mimes).await.is_err() {
                                break;
                            }
                        }
                    }
                }
            }
        });

        let serve_sem = Arc::new(Semaphore::new(MAX_CONCURRENT_FETCH_SERVES));
        let mut handlers = JoinSet::new();
        let mut last_remote_seq: u64 = 0;
        let mut cancel_in = cancel_rx;

        loop {
            while handlers.try_join_next().is_some() {}
            if *cancel_in.borrow() {
                break;
            }
            tokio::select! {
                biased;
                _ = cancel_in.changed() => break,
                accepted = connection.accept_bi() => {
                    let (send, mut recv) = match accepted {
                        Ok(pair) => pair,
                        Err(_) => break,
                    };
                    let mut tag = [0u8; 1];
                    match tokio::time::timeout(CLIP_CONTROL_IO_TIMEOUT, recv.read_exact(&mut tag)).await {
                        Ok(Ok(())) => {}
                        _ => {
                            let _ = recv.stop(0u32.into());
                            continue;
                        }
                    }
                    match tag[0] {
                        CLIP_MSG_OFFER => {
                            if let Ok((seq, mimes)) = read_offer_body(&mut recv).await {
                                if seq > last_remote_seq {
                                    last_remote_seq = seq;
                                    hub.set_remote_offer(seq, mimes);
                                }
                                let mut s = send;
                                let _ = s.set_priority(CLIP_STREAM_PRIORITY);
                                let _ = tokio::time::timeout(
                                    CLIP_CONTROL_IO_TIMEOUT,
                                    s.write_all(&[CLIP_OFFER_ACK]),
                                )
                                .await;
                                let _ = s.finish();
                            } else {
                                let _ = recv.stop(0u32.into());
                            }
                        }
                        CLIP_MSG_FETCH => {
                            let Ok(permit) = serve_sem.clone().try_acquire_owned() else {
                                let mut s = send;
                                let _ = s.write_all(&[CLIP_FETCH_UNAVAILABLE]).await;
                                let _ = s.finish();
                                continue;
                            };
                            let hub_clone = hub.clone();
                            handlers.spawn(async move {
                                let _permit = permit;
                                handle_fetch_request(hub_clone, send, recv).await;
                            });
                        }
                        _ => {
                            let _ = recv.stop(0u32.into());
                        }
                    }
                }
            }
        }

        hub.set_active_connection(None);
        outbound_offers.abort();
        let _ = tokio::time::timeout(CLIP_JOIN_DRAIN_BUDGET, outbound_offers).await;
        handlers.abort_all();
        let _ = tokio::time::timeout(CLIP_JOIN_DRAIN_BUDGET, async {
            while handlers.join_next().await.is_some() {}
        })
        .await;
    })
}

async fn send_offer(
    connection: &Connection,
    seq: u64,
    mimes: &[String],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let payload = encode_offer_frame(seq, mimes)?;
    let (mut send, mut recv) =
        tokio::time::timeout(CLIP_CONTROL_IO_TIMEOUT, connection.open_bi()).await??;
    let _ = send.set_priority(CLIP_STREAM_PRIORITY);
    tokio::time::timeout(CLIP_CONTROL_IO_TIMEOUT, send.write_all(&payload)).await??;
    send.finish()?;
    let mut ack = [0u8; 1];
    let _ = tokio::time::timeout(CLIP_CONTROL_IO_TIMEOUT, recv.read_exact(&mut ack)).await;
    Ok(())
}

async fn read_offer_body(recv: &mut RecvStream) -> Result<(u64, Vec<String>), &'static str> {
    let mut body = tokio::time::timeout(
        CLIP_CONTROL_IO_TIMEOUT,
        recv.read_to_end(MAX_OFFER_FRAME_BYTES),
    )
    .await
    .map_err(|_| "offer read timed out")?
    .map_err(|_| "offer read failed")?;
    let mut full = Vec::with_capacity(1 + body.len());
    full.push(CLIP_MSG_OFFER);
    full.append(&mut body);
    decode_offer_frame(&full)
}

async fn handle_fetch_request(hub: ClipboardHub, mut send: SendStream, mut recv: RecvStream) {
    let _ = send.set_priority(CLIP_STREAM_PRIORITY);
    let Ok(Ok(mut body)) = tokio::time::timeout(
        CLIP_CONTROL_IO_TIMEOUT,
        recv.read_to_end(MAX_FETCH_REQ_BYTES),
    )
    .await
    else {
        let _ = send.write_all(&[CLIP_FETCH_UNAVAILABLE]).await;
        let _ = send.finish();
        return;
    };
    let mut full = Vec::with_capacity(1 + body.len());
    full.push(CLIP_MSG_FETCH);
    full.append(&mut body);
    let Ok((seq, mime)) = decode_fetch_request(&full) else {
        let _ = send.write_all(&[CLIP_FETCH_UNAVAILABLE]).await;
        let _ = send.finish();
        return;
    };

    let Ok((pipe_read, pipe_write)) = std::io::pipe() else {
        let _ = send.write_all(&[CLIP_FETCH_UNAVAILABLE]).await;
        let _ = send.finish();
        return;
    };

    let write_fd: OwnedFd = pipe_write.into();
    if hub.receive_local(seq, mime, write_fd).await.is_err() {
        let _ = send.write_all(&[CLIP_FETCH_UNAVAILABLE]).await;
        let _ = send.finish();
        return;
    }

    let read_fd: OwnedFd = pipe_read.into();
    let Ok(mut async_pipe) = tokio::net::unix::pipe::Receiver::from_owned_fd(read_fd) else {
        let _ = send.write_all(&[CLIP_FETCH_UNAVAILABLE]).await;
        let _ = send.finish();
        return;
    };

    if tokio::time::timeout(CLIP_CONTROL_IO_TIMEOUT, send.write_all(&[CLIP_FETCH_OK]))
        .await
        .is_err()
    {
        return;
    }

    let deadline = Instant::now() + CLIP_FETCH_TIMEOUT;
    let mut total: usize = 0;
    let mut buf = [0u8; 16 * 1024];
    loop {
        if Instant::now() >= deadline {
            let _ = send.reset(1u32.into());
            return;
        }
        let step_deadline = std::cmp::min(deadline, Instant::now() + CLIP_PIPE_IDLE_TIMEOUT);
        match tokio::time::timeout_at(step_deadline, async_pipe.read(&mut buf)).await {
            Ok(Ok(0)) => {
                let _ = send.finish();
                return;
            }
            Ok(Ok(n)) => {
                if total + n > MAX_CLIPBOARD_BYTES {
                    let _ = send.reset(2u32.into());
                    return;
                }
                total += n;
                if tokio::time::timeout_at(deadline, send.write_all(&buf[..n]))
                    .await
                    .is_err()
                {
                    let _ = send.reset(1u32.into());
                    return;
                }
            }
            Ok(Err(_)) | Err(_) => {
                let _ = send.reset(1u32.into());
                return;
            }
        }
    }
}

pub async fn fetch_remote_to_fd(
    connection: Connection,
    seq: u64,
    mime: String,
    target_fd: OwnedFd,
) -> Result<usize, &'static str> {
    let req = encode_fetch_request(seq, &mime).map_err(|_| "invalid fetch request")?;
    let deadline = Instant::now() + CLIP_FETCH_TIMEOUT;
    let (mut send, mut recv) = tokio::time::timeout_at(deadline, connection.open_bi())
        .await
        .map_err(|_| "open_bi timed out")?
        .map_err(|_| "open_bi failed")?;
    let _ = send.set_priority(CLIP_STREAM_PRIORITY);
    tokio::time::timeout_at(deadline, send.write_all(&req))
        .await
        .map_err(|_| "fetch request write timed out")?
        .map_err(|_| "fetch request write failed")?;
    send.finish().map_err(|_| "fetch request finish failed")?;

    let mut status = [0u8; 1];
    tokio::time::timeout_at(deadline, recv.read_exact(&mut status))
        .await
        .map_err(|_| "fetch status timed out")?
        .map_err(|_| "fetch status read failed")?;
    if status[0] != CLIP_FETCH_OK {
        let _ = recv.stop(0u32.into());
        return Err("remote offer unavailable");
    }

    let is_fifo = std::fs::File::from(target_fd.as_fd().try_clone_to_owned().map_err(|_| "dup failed")?)
        .metadata()
        .map(|m| m.file_type().is_fifo())
        .unwrap_or(false);

    if is_fifo {
        let mut async_out = tokio::net::unix::pipe::Sender::from_owned_fd(target_fd)
            .map_err(|_| "async pipe sender failed")?;
        let mut buf = [0u8; 16 * 1024];
        let mut total = 0usize;
        loop {
            let n = tokio::time::timeout_at(deadline, recv.read(&mut buf))
                .await
                .map_err(|_| "fetch payload timed out")?
                .map_err(|_| "fetch payload failed")?;
            let Some(n) = n else {
                return Ok(total);
            };
            if total + n > MAX_CLIPBOARD_BYTES {
                let _ = recv.stop(2u32.into());
                return Err("clipboard payload exceeded max bytes");
            }
            total += n;
            tokio::time::timeout_at(deadline, async_out.write_all(&buf[..n]))
                .await
                .map_err(|_| "paste pipe write timed out")?
                .map_err(|_| "paste pipe closed")?;
        }
    } else {
        let mut file = std::fs::File::from(target_fd);
        let mut buf = [0u8; 16 * 1024];
        let mut total = 0usize;
        loop {
            let n = tokio::time::timeout_at(deadline, recv.read(&mut buf))
                .await
                .map_err(|_| "fetch payload timed out")?
                .map_err(|_| "fetch payload failed")?;
            let Some(n) = n else {
                return Ok(total);
            };
            if total + n > MAX_CLIPBOARD_BYTES {
                let _ = recv.stop(2u32.into());
                return Err("clipboard payload exceeded max bytes");
            }
            total += n;
            use std::io::Write;
            let chunk = buf[..n].to_vec();
            file = tokio::task::spawn_blocking(move || -> io::Result<std::fs::File> {
                file.write_all(&chunk)?;
                Ok(file)
            })
            .await
            .map_err(|_| "paste write join failed")?
            .map_err(|_| "paste write failed")?;
        }
    }
}

pub fn encode_offer_frame(seq: u64, mimes: &[String]) -> Result<Vec<u8>, &'static str> {
    if mimes.len() > MAX_MIME_TYPES {
        return Err("too many mime types");
    }
    let mut out = Vec::with_capacity(11 + mimes.len() * 24);
    out.push(CLIP_MSG_OFFER);
    out.extend_from_slice(&seq.to_be_bytes());
    out.extend_from_slice(&(mimes.len() as u16).to_be_bytes());
    for mime in mimes {
        if !is_valid_mime_str(mime) {
            return Err("invalid mime type");
        }
        out.extend_from_slice(&(mime.len() as u16).to_be_bytes());
        out.extend_from_slice(mime.as_bytes());
    }
    Ok(out)
}

pub fn decode_offer_frame(bytes: &[u8]) -> Result<(u64, Vec<String>), &'static str> {
    if bytes.len() < 11 || bytes[0] != CLIP_MSG_OFFER {
        return Err("invalid offer header");
    }
    let seq = u64::from_be_bytes(bytes[1..9].try_into().unwrap());
    let count = u16::from_be_bytes(bytes[9..11].try_into().unwrap()) as usize;
    if count > MAX_MIME_TYPES {
        return Err("too many mime types");
    }
    let mut pos = 11usize;
    let mut seen = BTreeSet::new();
    let mut mimes = Vec::with_capacity(count);
    for _ in 0..count {
        if pos + 2 > bytes.len() {
            return Err("truncated mime len");
        }
        let len = u16::from_be_bytes(bytes[pos..pos + 2].try_into().unwrap()) as usize;
        pos += 2;
        if len == 0 || len > MAX_MIME_LEN || pos + len > bytes.len() {
            return Err("invalid mime len");
        }
        let s = std::str::from_utf8(&bytes[pos..pos + len]).map_err(|_| "non-utf8 mime")?;
        pos += len;
        if !is_valid_mime_str(s) || is_filtered_mime(s) {
            return Err("disallowed mime type");
        }
        if seen.insert(s.to_owned()) {
            mimes.push(s.to_owned());
        }
    }
    if pos != bytes.len() {
        return Err("trailing offer bytes");
    }
    Ok((seq, mimes))
}

pub fn encode_fetch_request(seq: u64, mime: &str) -> Result<Vec<u8>, &'static str> {
    if !is_valid_mime_str(mime) {
        return Err("invalid mime type");
    }
    let mut out = Vec::with_capacity(11 + mime.len());
    out.push(CLIP_MSG_FETCH);
    out.extend_from_slice(&seq.to_be_bytes());
    out.extend_from_slice(&(mime.len() as u16).to_be_bytes());
    out.extend_from_slice(mime.as_bytes());
    Ok(out)
}

pub fn decode_fetch_request(bytes: &[u8]) -> Result<(u64, String), &'static str> {
    if bytes.len() < 11 || bytes[0] != CLIP_MSG_FETCH {
        return Err("invalid fetch header");
    }
    let seq = u64::from_be_bytes(bytes[1..9].try_into().unwrap());
    let len = u16::from_be_bytes(bytes[9..11].try_into().unwrap()) as usize;
    if len == 0 || len > MAX_MIME_LEN || 11 + len != bytes.len() {
        return Err("invalid fetch mime len");
    }
    let mime = std::str::from_utf8(&bytes[11..]).map_err(|_| "non-utf8 mime")?;
    if !is_valid_mime_str(mime) || is_filtered_mime(mime) {
        return Err("disallowed mime type");
    }
    Ok((seq, mime.to_owned()))
}

fn is_valid_mime_str(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_MIME_LEN
        && !s.bytes().any(|b| b < 0x20 || b == 0x7f)
}

fn is_filtered_mime(s: &str) -> bool {
    matches!(
        s,
        SECRET_HINT_MIME
            | "TARGETS"
            | "MULTIPLE"
            | "TIMESTAMP"
            | "DELETE"
            | "SAVE_TARGETS"
            | "ATOM"
            | "INCR"
            | "INSERT_PROPERTY"
            | "INSERT_SELECTION"
    )
}

pub fn normalize_mime_list(raw: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for m in raw {
        if is_valid_mime_str(m) && !is_filtered_mime(m) && seen.insert(m.clone()) {
            out.push(m.clone());
            if out.len() >= MAX_MIME_TYPES {
                break;
            }
        }
    }
    out
}

pub fn is_secret_hint_bytes(bytes: &[u8]) -> bool {
    let Ok(s) = std::str::from_utf8(bytes) else {
        return true;
    };
    s.trim().eq_ignore_ascii_case("secret")
}

async fn run_wayland_supervisor(
    mut rx: mpsc::UnboundedReceiver<WaylandMsg>,
    self_tx: mpsc::UnboundedSender<WaylandMsg>,
    local_offer_tx: watch::Sender<Option<LocalOfferMeta>>,
    active_conn: Arc<std::sync::Mutex<Option<Connection>>>,
    mut shutdown_rx: watch::Receiver<bool>,
) {
    loop {
        if *shutdown_rx.borrow() {
            break;
        }
        if let Err(err) = run_wayland_once(
            &mut rx,
            &self_tx,
            &local_offer_tx,
            &active_conn,
            &mut shutdown_rx,
        )
        .await
        {
            eprintln!("cursor-bridge: clipboard wayland loop stopped: {err}");
        }
        if *shutdown_rx.borrow() {
            break;
        }
        // Drain any stale queued commands before reconnecting.
        while let Ok(msg) = rx.try_recv() {
            if let WaylandMsg::ReceiveLocal { reply, .. } = msg {
                let _ = reply.send(Err("wayland reconnecting"));
            }
        }
        tokio::select! {
            biased;
            _ = shutdown_rx.changed() => break,
            _ = tokio::time::sleep(WAYLAND_RECONNECT_BACKOFF) => {}
        }
    }
}

enum ProtocolBackend {
    Ext {
        manager: ext_data_control_manager_v1::ExtDataControlManagerV1,
        device: Option<ext_data_control_device_v1::ExtDataControlDeviceV1>,
    },
    Wlr {
        manager: zwlr_data_control_manager_v1::ZwlrDataControlManagerV1,
        device: Option<zwlr_data_control_device_v1::ZwlrDataControlDeviceV1>,
    },
}

enum AnyOffer {
    Ext(ext_data_control_offer_v1::ExtDataControlOfferV1),
    Wlr(zwlr_data_control_offer_v1::ZwlrDataControlOfferV1),
}

impl AnyOffer {
    fn receive(&self, mime: String, fd: std::os::fd::BorrowedFd<'_>) {
        match self {
            Self::Ext(o) => o.receive(mime, fd),
            Self::Wlr(o) => o.receive(mime, fd),
        }
    }

    fn destroy(&self) {
        match self {
            Self::Ext(o) => o.destroy(),
            Self::Wlr(o) => o.destroy(),
        }
    }
}

enum AnySource {
    Ext(ext_data_control_source_v1::ExtDataControlSourceV1),
    Wlr(zwlr_data_control_source_v1::ZwlrDataControlSourceV1),
}

impl AnySource {
    fn destroy(&self) {
        match self {
            Self::Ext(s) => s.destroy(),
            Self::Wlr(s) => s.destroy(),
        }
    }
}

struct ActiveLocalOffer {
    seq: u64,
    offer: AnyOffer,
    mimes: Vec<String>,
}

struct ActiveRemoteSource {
    token: u64,
    remote_seq: u64,
    source: AnySource,
}

#[derive(Clone, Copy)]
enum SyncPhase {
    Before,
    After,
}
struct WlState {
    conn: WlConnection,
    seat: Option<wl_seat::WlSeat>,
    ext_manager: Option<ext_data_control_manager_v1::ExtDataControlManagerV1>,
    wlr_manager: Option<zwlr_data_control_manager_v1::ZwlrDataControlManagerV1>,
    backend: Option<ProtocolBackend>,

    pending_offers: HashMap<wayland_client::backend::ObjectId, (AnyOffer, Vec<String>)>,
    remote_sync_depth: usize,
    next_token: u64,
    next_local_seq: u64,

    active_remote_source: Option<ActiveRemoteSource>,
    active_local_offer: Option<ActiveLocalOffer>,
    pending_secret_candidate: Option<(u64, AnyOffer, Vec<String>)>,
    latest_candidate_seq: u64,

    local_offer_tx: watch::Sender<Option<LocalOfferMeta>>,
    self_tx: mpsc::UnboundedSender<WaylandMsg>,
    active_conn: Arc<std::sync::Mutex<Option<Connection>>>,
    fetch_sem: Arc<Semaphore>,
    fetch_tasks: JoinSet<()>,
}

impl WlState {
    fn clear_local_offer(&mut self) {
        if let Some(old) = self.active_local_offer.take() {
            old.offer.destroy();
        }
        if let Some((_, old_cand, _)) = self.pending_secret_candidate.take() {
            old_cand.destroy();
        }
        let _ = self.local_offer_tx.send(None);
    }

    fn clear_remote_source(&mut self) {
        if let Some(old) = self.active_remote_source.take() {
            old.source.destroy();
        }
    }

    fn handle_selection(&mut self, offer_id: Option<wayland_client::backend::ObjectId>, qh: &QueueHandle<Self>) {
        let Some(oid) = offer_id else {
            if self.remote_sync_depth > 0 {
                return;
            }
            self.clear_local_offer();
            return;
        };

        let Some((offer, raw_mimes)) = self.pending_offers.remove(&oid) else {
            return;
        };

        if self.remote_sync_depth > 0 {
            offer.destroy();
            return;
        }
        // Genuine local selection: discard any stale remote source and previous local offer.
        self.clear_remote_source();
        self.clear_local_offer();

        let normalized = normalize_mime_list(&raw_mimes);
        if normalized.is_empty() {
            offer.destroy();
            return;
        }

        self.next_local_seq += 1;
        let seq = self.next_local_seq;
        self.latest_candidate_seq = seq;

        let has_secret_hint = raw_mimes.iter().any(|m| m == SECRET_HINT_MIME);
        if has_secret_hint {
            if let Ok((pipe_read, pipe_write)) = std::io::pipe() {
                offer.receive(SECRET_HINT_MIME.to_string(), pipe_write.as_fd());
                let _ = self.conn.flush();
                drop(pipe_write);
                self.pending_secret_candidate = Some((seq, offer, normalized.clone()));
                let tx = self.self_tx.clone();
                let _ = qh;
                tokio::spawn(async move {
                    let is_secret = check_secret_pipe(pipe_read).await;
                    if is_secret {
                        let _ = tx.send(WaylandMsg::RejectCandidate { candidate_seq: seq });
                    } else {
                        let _ = tx.send(WaylandMsg::PromoteCandidate {
                            candidate_seq: seq,
                            mimes: normalized,
                        });
                    }
                });
            } else {
                // Fail-closed if pipe cannot be allocated.
                offer.destroy();
            }
        } else {
            self.active_local_offer = Some(ActiveLocalOffer {
                seq,
                offer,
                mimes: normalized.clone(),
            });
            let _ = self.local_offer_tx.send(Some(LocalOfferMeta {
                seq,
                mimes: normalized,
            }));
        }
    }

    fn set_remote_offer(&mut self, seq: u64, mimes: Vec<String>, qh: &QueueHandle<Self>) {
        let normalized = normalize_mime_list(&mimes);
        if normalized.is_empty() {
            return;
        }
        if self.backend.is_none() {
            return;
        }

        // Drop local offer metadata when remote selection takes over.
        self.clear_local_offer();
        self.clear_remote_source();
        let Some(backend) = &self.backend else {
            return;
        };
        self.next_token += 1;
        let token = self.next_token;

        let _ = self.conn.display().sync(qh, SyncPhase::Before);
        let source = match backend {
            ProtocolBackend::Ext { manager, device } => {
                let Some(dev) = device else { return; };
                let src = manager.create_data_source(qh, token);
                for mime in &normalized {
                    src.offer(mime.clone());
                }
                dev.set_selection(Some(&src));
                AnySource::Ext(src)
            }
            ProtocolBackend::Wlr { manager, device } => {
                let Some(dev) = device else { return; };
                let src = manager.create_data_source(qh, token);
                for mime in &normalized {
                    src.offer(mime.clone());
                }
                dev.set_selection(Some(&src));
                AnySource::Wlr(src)
            }
        };

        let _ = self.conn.display().sync(qh, SyncPhase::After);
        let _ = self.conn.flush();
        self.active_remote_source = Some(ActiveRemoteSource {
            token,
            remote_seq: seq,
            source,
        });
    }

    fn handle_source_send(&mut self, token: u64, mime: String, fd: OwnedFd) {
        let Some(active) = &self.active_remote_source else {
            return;
        };
        if active.token != token || !is_valid_mime_str(&mime) || is_filtered_mime(&mime) {
            return;
        }
        let conn_opt = {
            let guard = self.active_conn.lock().unwrap_or_else(|e| e.into_inner());
            guard.clone()
        };
        let Some(conn) = conn_opt else {
            return;
        };
        let Ok(permit) = self.fetch_sem.clone().try_acquire_owned() else {
            return;
        };
        let remote_seq = active.remote_seq;
        self.fetch_tasks.spawn(async move {
            let _permit = permit;
            let _ = fetch_remote_to_fd(conn, remote_seq, mime, fd).await;
        });
    }

    fn handle_source_cancelled(&mut self, token: u64) {
        if self.active_remote_source.as_ref().is_some_and(|s| s.token == token) {
            self.clear_remote_source();
        }
    }
}

async fn check_secret_pipe(pipe_read: std::io::PipeReader) -> bool {
    let read_fd: OwnedFd = pipe_read.into();
    let Ok(mut async_pipe) = tokio::net::unix::pipe::Receiver::from_owned_fd(read_fd) else {
        return true;
    };
    let mut buf = Vec::with_capacity(MAX_SECRET_HINT_BYTES);
    let mut chunk = [0u8; MAX_SECRET_HINT_BYTES];
    let deadline = Instant::now() + SECRET_HINT_TIMEOUT;
    loop {
        match tokio::time::timeout_at(deadline, async_pipe.read(&mut chunk)).await {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => {
                let take = n.min(MAX_SECRET_HINT_BYTES.saturating_sub(buf.len()));
                buf.extend_from_slice(&chunk[..take]);
                if buf.len() >= MAX_SECRET_HINT_BYTES {
                    break;
                }
            }
            Ok(Err(_)) | Err(_) => return true,
        }
    }
    is_secret_hint_bytes(&buf)
}

async fn run_wayland_once(
    rx: &mut mpsc::UnboundedReceiver<WaylandMsg>,
    self_tx: &mpsc::UnboundedSender<WaylandMsg>,
    local_offer_tx: &watch::Sender<Option<LocalOfferMeta>>,
    active_conn: &Arc<std::sync::Mutex<Option<Connection>>>,
    shutdown_rx: &mut watch::Receiver<bool>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let conn = WlConnection::connect_to_env()?;
    let mut event_queue = conn.new_event_queue::<WlState>();
    let qh = event_queue.handle();

    let mut state = WlState {
        conn: conn.clone(),
        seat: None,
        ext_manager: None,
        wlr_manager: None,
        backend: None,
        pending_offers: HashMap::new(),
        remote_sync_depth: 0,
        next_token: 0,
        next_local_seq: 0,
        active_remote_source: None,
        active_local_offer: None,
        pending_secret_candidate: None,
        latest_candidate_seq: 0,
        local_offer_tx: local_offer_tx.clone(),
        self_tx: self_tx.clone(),
        active_conn: active_conn.clone(),
        fetch_sem: Arc::new(Semaphore::new(MAX_CONCURRENT_REMOTE_FETCHES)),
        fetch_tasks: JoinSet::new(),
    };

    let display = conn.display();
    let _registry = display.get_registry(&qh, ());
    event_queue.roundtrip(&mut state)?;

    let seat = state.seat.clone().ok_or("wl_seat not found")?;
    if let Some(ext) = state.ext_manager.take() {
        let dev = ext.get_data_device(&seat, &qh, ());
        state.backend = Some(ProtocolBackend::Ext {
            manager: ext,
            device: Some(dev),
        });
    } else if let Some(wlr) = state.wlr_manager.take() {
        let dev = wlr.get_data_device(&seat, &qh, ());
        state.backend = Some(ProtocolBackend::Wlr {
            manager: wlr,
            device: Some(dev),
        });
    } else {
        return Err("neither ext_data_control_manager_v1 nor zwlr_data_control_manager_v1 is supported".into());
    }
    event_queue.roundtrip(&mut state)?;

    let wl_stream = {
        event_queue.dispatch_pending(&mut state)?;
        let owned_fd = loop {
            if let Some(guard) = conn.prepare_read() {
                break guard.connection_fd().try_clone_to_owned()?;
            }
            event_queue.dispatch_pending(&mut state)?;
        };
        let std_stream = std::os::unix::net::UnixStream::from(owned_fd);
        std_stream.set_nonblocking(true)?;
        tokio::net::UnixStream::from_std(std_stream)?
    };

    loop {
        while state.fetch_tasks.try_join_next().is_some() {}
        event_queue.dispatch_pending(&mut state)?;
        let _ = conn.flush();

        if *shutdown_rx.borrow() {
            break;
        }

        if let Some(guard) = conn.prepare_read() {
            tokio::select! {
                biased;
                _ = shutdown_rx.changed() => {
                    drop(guard);
                    break;
                }
                msg = rx.recv() => {
                    drop(guard);
                    let Some(msg) = msg else { break; };
                    handle_wayland_msg(&mut state, &qh, msg);
                }
                ready = wl_stream.readable() => {
                    ready?;
                    let mut guard_opt = Some(guard);
                    let mut read_err = None;
                    let _ = wl_stream.try_io(tokio::io::Interest::READABLE, || {
                        if let Some(g) = guard_opt.take() {
                            match g.read() {
                                Ok(_) => Ok(()),
                                Err(WaylandError::Io(e)) if e.kind() == io::ErrorKind::WouldBlock => {
                                    Err(io::Error::from(io::ErrorKind::WouldBlock))
                                }
                                Err(e) => {
                                    read_err = Some(e);
                                    Ok(())
                                }
                            }
                        } else {
                            Ok(())
                        }
                    });
                    if let Some(e) = read_err {
                        return Err(e.into());
                    }
                }
            }
        }
    }

    state.clear_local_offer();
    state.clear_remote_source();
    let _ = conn.flush();
    state.fetch_tasks.abort_all();
    while state.fetch_tasks.join_next().await.is_some() {}
    Ok(())
}

fn handle_wayland_msg(state: &mut WlState, qh: &QueueHandle<WlState>, msg: WaylandMsg) {
    match msg {
        WaylandMsg::SetRemoteOffer { seq, mimes } => {
            state.set_remote_offer(seq, mimes, qh);
        }
        WaylandMsg::ReceiveLocal {
            seq,
            mime,
            write_fd,
            reply,
        } => {
            let res = if let Some(active) = &state.active_local_offer {
                if active.seq == seq && active.mimes.iter().any(|m| m == &mime) {
                    active.offer.receive(mime, write_fd.as_fd());
                    let _ = state.conn.flush();
                    Ok(())
                } else {
                    Err("offer seq or mime mismatch")
                }
            } else {
                Err("no active local offer")
            };
            drop(write_fd);
            let _ = reply.send(res);
        }
        WaylandMsg::PromoteCandidate {
            candidate_seq,
            mimes,
        } => {
            if let Some((seq, offer, _)) = state.pending_secret_candidate.take() {
                if seq == candidate_seq && state.latest_candidate_seq == candidate_seq {
                    state.active_local_offer = Some(ActiveLocalOffer {
                        seq,
                        offer,
                        mimes: mimes.clone(),
                    });
                    let _ = state
                        .local_offer_tx
                        .send(Some(LocalOfferMeta { seq, mimes }));
                } else {
                    offer.destroy();
                }
            }
        }
        WaylandMsg::RejectCandidate { candidate_seq } => {
            if state
                .pending_secret_candidate
                .as_ref()
                .is_some_and(|(seq, _, _)| *seq == candidate_seq)
            {
                if let Some((_, offer, _)) = state.pending_secret_candidate.take() {
                    offer.destroy();
                }
            }
        }
    }
}

impl Dispatch<wl_registry::WlRegistry, ()> for WlState {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &WlConnection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            match interface.as_str() {
                "wl_seat" if state.seat.is_none() => {
                    state.seat = Some(registry.bind::<wl_seat::WlSeat, _, _>(name, version.min(9), qh, ()));
                }
                "ext_data_control_manager_v1" if state.ext_manager.is_none() => {
                    state.ext_manager = Some(
                        registry.bind::<ext_data_control_manager_v1::ExtDataControlManagerV1, _, _>(
                            name,
                            version.min(1),
                            qh,
                            (),
                        ),
                    );
                }
                "zwlr_data_control_manager_v1" if state.wlr_manager.is_none() => {
                    state.wlr_manager = Some(
                        registry.bind::<zwlr_data_control_manager_v1::ZwlrDataControlManagerV1, _, _>(
                            name,
                            version.min(2),
                            qh,
                            (),
                        ),
                    );
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for WlState {
    fn event(
        _: &mut Self,
        _: &wl_seat::WlSeat,
        _: wl_seat::Event,
        _: &(),
        _: &WlConnection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<wl_callback::WlCallback, SyncPhase> for WlState {
    fn event(
        state: &mut Self,
        _: &wl_callback::WlCallback,
        event: wl_callback::Event,
        phase: &SyncPhase,
        _: &WlConnection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_callback::Event::Done { .. } = event {
            match phase {
                SyncPhase::Before => state.remote_sync_depth += 1,
                SyncPhase::After => {
                    state.remote_sync_depth = state.remote_sync_depth.saturating_sub(1);
                }
            }
        }
    }
}

impl Dispatch<ext_data_control_manager_v1::ExtDataControlManagerV1, ()> for WlState {
    fn event(
        _: &mut Self,
        _: &ext_data_control_manager_v1::ExtDataControlManagerV1,
        _: ext_data_control_manager_v1::Event,
        _: &(),
        _: &WlConnection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ext_data_control_device_v1::ExtDataControlDeviceV1, ()> for WlState {
    fn event(
        state: &mut Self,
        _: &ext_data_control_device_v1::ExtDataControlDeviceV1,
        event: ext_data_control_device_v1::Event,
        _: &(),
        _: &WlConnection,
        qh: &QueueHandle<Self>,
    ) {
        match event {
            ext_data_control_device_v1::Event::DataOffer { id } => {
                let oid = id.id();
                state.pending_offers.insert(oid, (AnyOffer::Ext(id), Vec::new()));
            }
            ext_data_control_device_v1::Event::Selection { id } => {
                state.handle_selection(id.map(|o| o.id()), qh);
            }
            ext_data_control_device_v1::Event::PrimarySelection { id } => {
                if let Some(offer) = id {
                    let oid = offer.id();
                    state.pending_offers.remove(&oid);
                    offer.destroy();
                }
            }
            ext_data_control_device_v1::Event::Finished => {
                if let Some(ProtocolBackend::Ext { device, .. }) = &mut state.backend {
                    *device = None;
                }
            }
            _ => {}
        }
    }

    wayland_client::event_created_child!(
        WlState,
        ext_data_control_device_v1::ExtDataControlDeviceV1,
        [
            ext_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (ext_data_control_offer_v1::ExtDataControlOfferV1, ()),
        ]
    );
}

impl Dispatch<ext_data_control_offer_v1::ExtDataControlOfferV1, ()> for WlState {
    fn event(
        state: &mut Self,
        offer: &ext_data_control_offer_v1::ExtDataControlOfferV1,
        event: ext_data_control_offer_v1::Event,
        _: &(),
        _: &WlConnection,
        _: &QueueHandle<Self>,
    ) {
        if let ext_data_control_offer_v1::Event::Offer { mime_type } = event {
            if let Some((_, mimes)) = state.pending_offers.get_mut(&offer.id()) {
                if mimes.len() < MAX_RAW_OFFER_MIMES {
                    mimes.push(mime_type);
                }
            }
        }
    }
}

impl Dispatch<ext_data_control_source_v1::ExtDataControlSourceV1, u64> for WlState {
    fn event(
        state: &mut Self,
        _: &ext_data_control_source_v1::ExtDataControlSourceV1,
        event: ext_data_control_source_v1::Event,
        token: &u64,
        _: &WlConnection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            ext_data_control_source_v1::Event::Send { mime_type, fd } => {
                state.handle_source_send(*token, mime_type, fd);
            }
            ext_data_control_source_v1::Event::Cancelled => {
                state.handle_source_cancelled(*token);
            }
            _ => {}
        }
    }
}

impl Dispatch<zwlr_data_control_manager_v1::ZwlrDataControlManagerV1, ()> for WlState {
    fn event(
        _: &mut Self,
        _: &zwlr_data_control_manager_v1::ZwlrDataControlManagerV1,
        _: zwlr_data_control_manager_v1::Event,
        _: &(),
        _: &WlConnection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<zwlr_data_control_device_v1::ZwlrDataControlDeviceV1, ()> for WlState {
    fn event(
        state: &mut Self,
        _: &zwlr_data_control_device_v1::ZwlrDataControlDeviceV1,
        event: zwlr_data_control_device_v1::Event,
        _: &(),
        _: &WlConnection,
        qh: &QueueHandle<Self>,
    ) {
        match event {
            zwlr_data_control_device_v1::Event::DataOffer { id } => {
                let oid = id.id();
                state.pending_offers.insert(oid, (AnyOffer::Wlr(id), Vec::new()));
            }
            zwlr_data_control_device_v1::Event::Selection { id } => {
                state.handle_selection(id.map(|o| o.id()), qh);
            }
            zwlr_data_control_device_v1::Event::PrimarySelection { id } => {
                if let Some(offer) = id {
                    let oid = offer.id();
                    state.pending_offers.remove(&oid);
                    offer.destroy();
                }
            }
            zwlr_data_control_device_v1::Event::Finished => {
                if let Some(ProtocolBackend::Wlr { device, .. }) = &mut state.backend {
                    *device = None;
                }
            }
            _ => {}
        }
    }

    wayland_client::event_created_child!(
        WlState,
        zwlr_data_control_device_v1::ZwlrDataControlDeviceV1,
        [
            zwlr_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (zwlr_data_control_offer_v1::ZwlrDataControlOfferV1, ()),
        ]
    );
}

impl Dispatch<zwlr_data_control_offer_v1::ZwlrDataControlOfferV1, ()> for WlState {
    fn event(
        state: &mut Self,
        offer: &zwlr_data_control_offer_v1::ZwlrDataControlOfferV1,
        event: zwlr_data_control_offer_v1::Event,
        _: &(),
        _: &WlConnection,
        _: &QueueHandle<Self>,
    ) {
        if let zwlr_data_control_offer_v1::Event::Offer { mime_type } = event {
            if let Some((_, mimes)) = state.pending_offers.get_mut(&offer.id()) {
                if mimes.len() < MAX_RAW_OFFER_MIMES {
                    mimes.push(mime_type);
                }
            }
        }
    }
}

impl Dispatch<zwlr_data_control_source_v1::ZwlrDataControlSourceV1, u64> for WlState {
    fn event(
        state: &mut Self,
        _: &zwlr_data_control_source_v1::ZwlrDataControlSourceV1,
        event: zwlr_data_control_source_v1::Event,
        token: &u64,
        _: &WlConnection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            zwlr_data_control_source_v1::Event::Send { mime_type, fd } => {
                state.handle_source_send(*token, mime_type, fd);
            }
            zwlr_data_control_source_v1::Event::Cancelled => {
                state.handle_source_cancelled(*token);
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use quinn::{ClientConfig, Endpoint, EndpointConfig, ServerConfig, TokioRuntime};
    use rcgen::CertificateParams;
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
    use std::net::{Ipv4Addr, SocketAddr};

    fn test_quinn_pair() -> (Endpoint, Endpoint, SocketAddr) {
        let key = rcgen::KeyPair::generate().unwrap();
        let cert = CertificateParams::new(vec!["cursor-bridge".to_string()])
            .unwrap()
            .self_signed(&key)
            .unwrap();
        let cert_der = CertificateDer::from(cert.der().to_vec());
        let pkcs8 = PrivatePkcs8KeyDer::from(key.serialize_der());

        let verifier = Arc::new(crate::Verifier(cert_der.clone()));
        let srv_rustls = rustls::ServerConfig::builder()
            .with_client_cert_verifier(verifier.clone())
            .with_single_cert(vec![cert_der.clone()], PrivateKeyDer::Pkcs8(pkcs8.clone_key()))
            .unwrap();
        let mut srv_cfg = ServerConfig::with_crypto(Arc::new(
            quinn::crypto::rustls::QuicServerConfig::try_from(srv_rustls).unwrap(),
        ));
        srv_cfg.transport_config(crate::transport());

        let cli_rustls = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(verifier)
            .with_client_auth_cert(vec![cert_der], PrivateKeyDer::Pkcs8(pkcs8))
            .unwrap();
        let mut cli_cfg = ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(cli_rustls).unwrap(),
        ));
        cli_cfg.transport_config(crate::transport());

        let srv_sock = std::net::UdpSocket::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        srv_sock.set_nonblocking(true).unwrap();
        let srv_addr = srv_sock.local_addr().unwrap();
        let srv_ep =
            Endpoint::new(EndpointConfig::default(), Some(srv_cfg), srv_sock, Arc::new(TokioRuntime))
                .unwrap();

        let mut cli_ep = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        cli_ep.set_default_client_config(cli_cfg);
        (srv_ep, cli_ep, srv_addr)
    }

    fn spawn_mock_hub(
        mut shutdown_rx: watch::Receiver<bool>,
        local_offer_tx: watch::Sender<Option<LocalOfferMeta>>,
        local_offer_rx: watch::Receiver<Option<LocalOfferMeta>>,
        local_payloads: Arc<std::sync::Mutex<HashMap<(u64, String), Vec<u8>>>>,
        remote_offers_seen: Arc<std::sync::Mutex<Vec<(u64, Vec<String>)>>>,
    ) -> (ClipboardHub, tokio::task::JoinHandle<()>) {
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<HubCmd>();
        let active_conn = Arc::new(std::sync::Mutex::new(None));
        let hub = ClipboardHub {
            local_offer_rx,
            cmd_tx,
            active_conn,
        };
        let handle = tokio::spawn(async move {
            let _keep_tx = local_offer_tx;
            loop {
                tokio::select! {
                    biased;
                    _ = shutdown_rx.changed() => break,
                    cmd = cmd_rx.recv() => {
                        let Some(cmd) = cmd else { break; };
                        match cmd {
                            HubCmd::SetRemoteOffer { seq, mimes } => {
                                remote_offers_seen.lock().unwrap().push((seq, mimes));
                            }
                            HubCmd::ReceiveLocal { seq, mime, write_fd, reply } => {
                                let payload = local_payloads.lock().unwrap().get(&(seq, mime)).cloned();
                                match payload {
                                    Some(data) => {
                                        let _ = reply.send(Ok(()));
                                        tokio::task::spawn_blocking(move || {
                                            use std::io::Write;
                                            let mut f = std::fs::File::from(write_fd);
                                            let _ = f.write_all(&data);
                                        });
                                    }
                                    None => {
                                        let _ = reply.send(Err("not found"));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        });
        (hub, handle)
    }

    #[test]
    fn offer_and_fetch_wire_frames_round_trip_and_reject_invalid() {
        let mimes = vec![
            "text/plain;charset=utf-8".to_string(),
            "image/png".to_string(),
        ];
        let encoded = encode_offer_frame(42, &mimes).unwrap();
        let (seq, decoded) = decode_offer_frame(&encoded).unwrap();
        assert_eq!(seq, 42);
        assert_eq!(decoded, mimes);

        assert!(encode_offer_frame(1, &["".to_string()]).is_err());
        assert!(encode_offer_frame(1, &["text/plain\0".to_string()]).is_err());
        let too_many: Vec<String> = (0..=MAX_MIME_TYPES).map(|i| format!("text/x-{i}")).collect();
        assert!(encode_offer_frame(1, &too_many).is_err());

        let mut bad_secret = encode_offer_frame(1, &[SECRET_HINT_MIME.to_string()]).unwrap();
        assert!(decode_offer_frame(&bad_secret).is_err());
        bad_secret[0] = 99;
        assert!(decode_offer_frame(&bad_secret).is_err());

        let fetch = encode_fetch_request(7, "image/png").unwrap();
        let (f_seq, f_mime) = decode_fetch_request(&fetch).unwrap();
        assert_eq!(f_seq, 7);
        assert_eq!(f_mime, "image/png");
        assert!(decode_fetch_request(&fetch[..fetch.len() - 1]).is_err());
    }

    #[test]
    fn mime_normalization_and_secret_hint_filtering() {
        let raw = vec![
            "TARGETS".to_string(),
            "SAVE_TARGETS".to_string(),
            SECRET_HINT_MIME.to_string(),
            "text/plain;charset=utf-8".to_string(),
            "text/plain;charset=utf-8".to_string(),
            "bad\nmime".to_string(),
            "image/png".to_string(),
        ];
        assert_eq!(
            normalize_mime_list(&raw),
            vec!["text/plain;charset=utf-8", "image/png"]
        );

        assert!(is_secret_hint_bytes(b"secret"));
        assert!(is_secret_hint_bytes(b" SECRET \n"));
        assert!(is_secret_hint_bytes(&[0xff, 0xfe]));
        assert!(!is_secret_hint_bytes(b"public"));
        assert!(!is_secret_hint_bytes(b""));
    }

    #[tokio::test]
    async fn quic_clipboard_offer_and_lazy_fetch_end_to_end() {
        let (srv_ep, cli_ep, srv_addr) = test_quinn_pair();
        let srv_accept = tokio::spawn(async move {
            srv_ep.accept().await.unwrap().await.unwrap()
        });
        let cli_conn = cli_ep.connect(srv_addr, "cursor-bridge").unwrap().await.unwrap();
        let srv_conn = srv_accept.await.unwrap();

        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let (srv_offer_tx, srv_offer_rx) = watch::channel(None);
        let (cli_offer_tx, cli_offer_rx) = watch::channel(None);

        let srv_payloads = Arc::new(std::sync::Mutex::new(HashMap::new()));
        let cli_payloads = Arc::new(std::sync::Mutex::new(HashMap::new()));
        let srv_seen = Arc::new(std::sync::Mutex::new(Vec::new()));
        let cli_seen = Arc::new(std::sync::Mutex::new(Vec::new()));

        let (srv_hub, srv_hub_h) = spawn_mock_hub(
            shutdown_rx.clone(),
            srv_offer_tx.clone(),
            srv_offer_rx,
            srv_payloads.clone(),
            srv_seen.clone(),
        );
        let (cli_hub, cli_hub_h) = spawn_mock_hub(
            shutdown_rx.clone(),
            cli_offer_tx.clone(),
            cli_offer_rx,
            cli_payloads.clone(),
            cli_seen.clone(),
        );

        let (cancel_tx, cancel_rx) = watch::channel(false);
        let srv_sess = spawn_clipboard_session(srv_conn.clone(), srv_hub, cancel_rx.clone());
        let cli_sess = spawn_clipboard_session(cli_conn.clone(), cli_hub, cancel_rx);

        // Client copies rich text + PNG; server sees offer without data fetched yet.
        let png_bytes = vec![0x89, b'P', b'N', b'G', 1, 2, 3, 4];
        cli_payloads
            .lock()
            .unwrap()
            .insert((10, "image/png".to_string()), png_bytes.clone());
        cli_offer_tx
            .send(Some(LocalOfferMeta {
                seq: 10,
                mimes: vec!["text/plain".to_string(), "image/png".to_string()],
            }))
            .unwrap();

        for _ in 0..50 {
            if !srv_seen.lock().unwrap().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(
            srv_seen.lock().unwrap().as_slice(),
            &[(10, vec!["text/plain".to_string(), "image/png".to_string()])]
        );

        // Server pastes image/png lazily over QUIC bi-stream into a pipe.
        let (pr, pw) = std::io::pipe().unwrap();
        let fetched = fetch_remote_to_fd(srv_conn.clone(), 10, "image/png".to_string(), pw.into())
            .await
            .unwrap();
        assert_eq!(fetched, png_bytes.len());
        let mut got = Vec::new();
        std::io::Read::read_to_end(&mut std::io::BufReader::new(pr), &mut got).unwrap();
        assert_eq!(got, png_bytes);

        // Requesting unavailable seq or unoffered MIME returns error cleanly.
        let (_pr2, pw2) = std::io::pipe().unwrap();
        assert!(
            fetch_remote_to_fd(srv_conn.clone(), 999, "image/png".to_string(), pw2.into())
                .await
                .is_err()
        );

        // Reverse direction: server copies text, client receives offer & pastes lazily.
        srv_payloads
            .lock()
            .unwrap()
            .insert((3, "text/plain;charset=utf-8".to_string()), b"hello vm".to_vec());
        srv_offer_tx
            .send(Some(LocalOfferMeta {
                seq: 3,
                mimes: vec!["text/plain;charset=utf-8".to_string()],
            }))
            .unwrap();

        for _ in 0..50 {
            if !cli_seen.lock().unwrap().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(
            cli_seen.lock().unwrap().as_slice(),
            &[(3, vec!["text/plain;charset=utf-8".to_string()])]
        );

        let (pr3, pw3) = std::io::pipe().unwrap();
        let fetched2 = fetch_remote_to_fd(
            cli_conn.clone(),
            3,
            "text/plain;charset=utf-8".to_string(),
            pw3.into(),
        )
        .await
        .unwrap();
        assert_eq!(fetched2, 8);
        let mut got2 = Vec::new();
        std::io::Read::read_to_end(&mut std::io::BufReader::new(pr3), &mut got2).unwrap();
        assert_eq!(got2, b"hello vm");

        // Cancel drains cleanly inside budget.
        let _ = cancel_tx.send(true);
        tokio::time::timeout(Duration::from_millis(200), srv_sess).await.unwrap().unwrap();
        tokio::time::timeout(Duration::from_millis(200), cli_sess).await.unwrap().unwrap();
        let _ = _shutdown_tx.send(true);
        let _ = tokio::time::timeout(Duration::from_millis(200), srv_hub_h).await;
        let _ = tokio::time::timeout(Duration::from_millis(200), cli_hub_h).await;
    }
}
