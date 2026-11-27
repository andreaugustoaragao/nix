//! Carry lan-mouse's datagrams across one mTLS QUIC connection.
//!
//! lan-mouse binds strictly to 127.0.0.1 on both hosts. The workstation cannot
//! route to prl-dev-vm (10.211.55.4), so prl-dev-vm dials workstation:4243 and
//! both directions ride the single QUIC connection.
//!
//! Native lan-mouse (`layer-shell` capture + `KeyScrollLock` release_bind)
//! owns capture release. cursor-bridge enforces mTLS, DP-2 readiness &
//! session/lock verification, exact D5 frame validation, bounded handshakes &
//! 500ms replacement/shutdown deadlines, and a single sequential RecoveryDriver
//! with V8-1 establishment-before-issuance over `bridge-serial` / `native-seat`.

mod clipboard;

use clipboard::{ClipboardHub, spawn_clipboard_session};
use quinn::{
    ClientConfig, Connection, Endpoint, EndpointConfig, IdleTimeout, ServerConfig, TokioRuntime,
    TransportConfig, VarInt,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use socket2::{Domain, SockAddr, Socket, Type};
use std::collections::{BTreeSet, VecDeque};
use std::error::Error;
use std::fs::File;
use std::io;
use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::num::NonZeroU32;
use std::os::unix::net::UnixStream as StdUnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::sync::{mpsc, oneshot, watch, Notify, Semaphore};
use tokio::task::JoinSet;
use tokio::time::Instant;

const EVENT_SIZE: usize = 21;
const PROTO_PING: u8 = 6;
const PROTO_ENTER: u8 = 8;
const PROTO_LEAVE: u8 = 9;
const PROTO_ACK: u8 = 10;

const FRAME_READ_TIMEOUT: Duration = Duration::from_millis(50);
const PLACEMENT_BUDGET: Duration = Duration::from_millis(250);
const COALESCE_WINDOW: Duration = Duration::from_millis(150);
const IDLE_CAPTURE_TIMEOUT: Duration = Duration::from_millis(750);
const REFUSAL_QUIET_WINDOW: Duration = Duration::from_millis(1250);
const RECOVERY_BUDGET: Duration = Duration::from_millis(100);
const RECOVERY_POLL_INTERVAL: Duration = Duration::from_millis(10);
const RECOVERY_BACKOFF: Duration = Duration::from_millis(50);
const CALLER_RECOVERY_WAIT_BUDGET: Duration = Duration::from_millis(150);
const REPLACEMENT_DECISION_BUDGET: Duration = Duration::from_millis(500);
const SHUTDOWN_DECISION_BUDGET: Duration = Duration::from_millis(500);
const BG_STOP_BUDGET: Duration = Duration::from_millis(50);
const COOPERATIVE_JOIN_BUDGET: Duration = Duration::from_millis(150);
const ABORT_DRAIN_BUDGET: Duration = Duration::from_millis(100);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

const MAX_CONCURRENT_HANDSHAKES: usize = 8;
const MAX_PENDING_ENTRY_FRAMES: usize = 32;
const MAX_HELD_BUTTONS: usize = 32;
const MAX_CONSECUTIVE_STREAM_DROPS: usize = 4;
const MAX_REAPER_CHILDREN: usize = 16;
const MAX_COMMAND_STDOUT_BYTES: usize = 65_536;
const LOCAL_TO_QUIC_CAP: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Role {
    Listen,
    Dial,
}

#[derive(Debug, Clone)]
struct Args {
    role: Role,
    quic_addr: SocketAddr,
    lan_local: SocketAddr,
    lan_peer: SocketAddr,
    cert: PathBuf,
    key: PathBuf,
    niri_bin: Option<PathBuf>,
    busctl_bin: Option<PathBuf>,
    enter_output: Option<String>,
    niri_socket: Option<PathBuf>,
    serial_floor_file: PathBuf,
    seat_state_file: PathBuf,
    clipboard: bool,
    #[cfg(test)]
    test_placement_hold: Option<Arc<Mutex<Option<(oneshot::Sender<()>, std::sync::mpsc::Receiver<()>)>>>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FrameKind {
    PointerMotion,
    PointerButton { button: u32, pressed: bool },
    PointerAxis,
    PointerAxis120,
    KeyboardKey { pressed: bool },
    KeyboardModifiers { non_zero: bool },
    Ping,
    Pong,
    Enter(u32),
    Leave(u32),
    Ack(u32),
}

impl FrameKind {
    fn is_stateful(self) -> bool {
        matches!(
            self,
            Self::PointerButton { .. }
                | Self::KeyboardKey { .. }
                | Self::KeyboardModifiers { .. }
                | Self::Enter(_)
                | Self::Leave(_)
        )
    }
}

fn validate_d5_frame(bytes: &[u8]) -> Result<FrameKind, &'static str> {
    let Some(&tag) = bytes.first() else {
        return Err("empty frame");
    };
    let expected_len = match tag {
        0 => 21,
        1 => 13,
        2 => 14,
        3 => 6,
        4 => 10,
        5 => 17,
        6 | 7 => 1,
        8..=10 => 5,
        _ => return Err("unknown event tag"),
    };
    if bytes.len() != expected_len {
        return Err("invalid event length");
    }
    match tag {
        0 => {
            let dx = f64::from_be_bytes(bytes[5..13].try_into().unwrap());
            let dy = f64::from_be_bytes(bytes[13..21].try_into().unwrap());
            if !dx.is_finite() || !dy.is_finite() || dx.abs() > 65536.0 || dy.abs() > 65536.0 {
                return Err("out-of-range pointer motion");
            }
            Ok(FrameKind::PointerMotion)
        }
        1 => {
            let button = u32::from_be_bytes(bytes[5..9].try_into().unwrap());
            let state = u32::from_be_bytes(bytes[9..13].try_into().unwrap());
            if state > 1 {
                return Err("invalid button state");
            }
            Ok(FrameKind::PointerButton {
                button,
                pressed: state == 1,
            })
        }
        2 => {
            let axis = bytes[5];
            let value = f64::from_be_bytes(bytes[6..14].try_into().unwrap());
            if axis > 1 || !value.is_finite() || value.abs() > 65536.0 {
                return Err("invalid pointer axis");
            }
            Ok(FrameKind::PointerAxis)
        }
        3 => {
            let axis = bytes[1];
            let value = i32::from_be_bytes(bytes[2..6].try_into().unwrap());
            if axis > 1 || value.unsigned_abs() > 120_000 {
                return Err("invalid pointer axis120");
            }
            Ok(FrameKind::PointerAxis120)
        }
        4 => {
            let state = bytes[9];
            if state > 1 {
                return Err("invalid key state");
            }
            Ok(FrameKind::KeyboardKey {
                pressed: state == 1,
            })
        }
        5 => {
            let non_zero = bytes[1..17].iter().any(|&b| b != 0);
            Ok(FrameKind::KeyboardModifiers { non_zero })
        }
        6 => Ok(FrameKind::Ping),
        7 => Ok(FrameKind::Pong),
        8 => Ok(FrameKind::Enter(u32::from_be_bytes(
            bytes[1..5].try_into().unwrap(),
        ))),
        9 => Ok(FrameKind::Leave(u32::from_be_bytes(
            bytes[1..5].try_into().unwrap(),
        ))),
        10 => Ok(FrameKind::Ack(u32::from_be_bytes(
            bytes[1..5].try_into().unwrap(),
        ))),
        _ => unreachable!(),
    }
}

fn encode_control_frame(tag: u8, serial: u32) -> [u8; 5] {
    let mut out = [0u8; 5];
    out[0] = tag;
    out[1..5].copy_from_slice(&serial.to_be_bytes());
    out
}

fn encode_button_release(button: u32) -> [u8; 13] {
    let mut out = [0u8; 13];
    out[0] = 1;
    out[5..9].copy_from_slice(&button.to_be_bytes());
    out
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RecoveryGate {
    Healthy,
    RecoveryRequired { required_epoch: u64 },
    ExhaustedFailClosed,
}

struct BridgeObligations {
    has_active_obligations: bool,
    pressed_buttons: BTreeSet<u32>,
    obligation_epoch: u64,
    recovery_gate: RecoveryGate,
    reaper: Vec<Child>,
    reserved_reaper_slots: usize,
}

impl BridgeObligations {
    fn new_startup_recovery() -> Self {
        Self {
            has_active_obligations: false,
            pressed_buttons: BTreeSet::new(),
            obligation_epoch: 1,
            recovery_gate: RecoveryGate::RecoveryRequired { required_epoch: 1 },
            reaper: Vec::new(),
            reserved_reaper_slots: 0,
        }
    }

    fn trigger_recovery(&mut self, notify: &Notify) -> u64 {
        if self.recovery_gate == RecoveryGate::ExhaustedFailClosed {
            return self.obligation_epoch;
        }
        self.obligation_epoch += 1;
        let epoch = self.obligation_epoch;
        self.recovery_gate = RecoveryGate::RecoveryRequired {
            required_epoch: epoch,
        };
        notify.notify_one();
        epoch
    }

    fn record_obligation(&mut self, kind: FrameKind) {
        match kind {
            FrameKind::Enter(_)
            | FrameKind::KeyboardKey { pressed: true }
            | FrameKind::KeyboardModifiers { non_zero: true } => {
                self.has_active_obligations = true;
                self.obligation_epoch += 1;
            }
            FrameKind::PointerButton {
                button,
                pressed: true,
            } => {
                if self.pressed_buttons.len() < MAX_HELD_BUTTONS {
                    self.pressed_buttons.insert(button);
                }
                self.has_active_obligations = true;
                self.obligation_epoch += 1;
            }
            _ => {}
        }
    }

    fn clear_released_button(&mut self, button: u32) {
        self.pressed_buttons.remove(&button);
    }

    fn sweep_reaper(&mut self) -> bool {
        self.reaper
            .retain_mut(|child| matches!(child.try_wait(), Ok(None)));
        self.reaper.is_empty() && self.reserved_reaper_slots == 0
    }

    fn reserve_reaper_slot(&mut self) -> bool {
        self.sweep_reaper();
        if self.reaper.len() + self.reserved_reaper_slots >= MAX_REAPER_CHILDREN {
            return false;
        }
        self.reserved_reaper_slots += 1;
        true
    }
}

struct SpawnedChildGuard {
    child: Option<Child>,
    obligations: Arc<Mutex<BridgeObligations>>,
}

impl SpawnedChildGuard {
    fn new(child: Child, obligations: Arc<Mutex<BridgeObligations>>) -> Self {
        Self {
            child: Some(child),
            obligations,
        }
    }

    fn try_wait(&mut self) -> io::Result<Option<std::process::ExitStatus>> {
        match self.child.as_mut() {
            Some(c) => {
                let res = c.try_wait()?;
                if res.is_some() {
                    self.child = None;
                    let mut ob = self.obligations.lock().unwrap_or_else(|e| e.into_inner());
                    ob.reserved_reaper_slots = ob.reserved_reaper_slots.saturating_sub(1);
                }
                Ok(res)
            }
            None => Ok(None),
        }
    }
}

impl Drop for SpawnedChildGuard {
    fn drop(&mut self) {
        let mut ob = self.obligations.lock().unwrap_or_else(|e| e.into_inner());
        ob.reserved_reaper_slots = ob.reserved_reaper_slots.saturating_sub(1);
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            if matches!(child.try_wait(), Ok(None) | Err(_)) {
                ob.reaper.push(child);
            }
        }
    }
}

#[derive(Default)]
struct ActiveRecoverySlot {
    entry: Option<(u64, NonZeroU32, oneshot::Sender<()>)>,
}

impl ActiveRecoverySlot {
    fn install(&mut self, epoch: u64, serial: NonZeroU32, tx: oneshot::Sender<()>) {
        self.entry = Some((epoch, serial, tx));
    }

    fn clear(&mut self) {
        self.entry = None;
    }

    fn deliver_ack(&mut self, serial: u32) -> bool {
        if let Some((_, expected, _)) = &self.entry {
            if expected.get() == serial {
                if let Some((_, _, tx)) = self.entry.take() {
                    let _ = tx.send(());
                }
                return true;
            }
        }
        false
    }
}

struct RecoverySlotGuard {
    slot: Arc<Mutex<ActiveRecoverySlot>>,
}

impl Drop for RecoverySlotGuard {
    fn drop(&mut self) {
        self.slot
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SeatState {
    Clean,
    Dirty,
    Unrecovered,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct SeatRecord {
    lifetime_id: String,
    state: SeatState,
    serial_established: bool,
}

fn atomic_write_file(path: &Path, content: &str) -> io::Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, content)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

fn read_floor_file(path: &Path) -> Result<Option<u32>, ()> {
    match std::fs::read_to_string(path) {
        Ok(text) => {
            let trimmed = text.trim();
            if let Some(v) = trimmed.strip_prefix("floor=") {
                v.parse::<u32>().map(Some).map_err(|_| ())
            } else {
                trimmed.parse::<u32>().map(Some).map_err(|_| ())
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(()),
    }
}

fn read_seat_file(path: &Path) -> Result<Option<SeatRecord>, ()> {
    match std::fs::read_to_string(path) {
        Ok(text) => {
            let mut lifetime_id = None;
            let mut state = None;
            let mut serial_established = None;
            for line in text.lines() {
                if let Some(v) = line.strip_prefix("lifetime_id=") {
                    if v.is_empty() {
                        return Err(());
                    }
                    lifetime_id = Some(v.to_string());
                } else if let Some(v) = line.strip_prefix("state=") {
                    state = match v {
                        "CLEAN" => Some(SeatState::Clean),
                        "DIRTY" => Some(SeatState::Dirty),
                        "UNRECOVERED" => Some(SeatState::Unrecovered),
                        _ => return Err(()),
                    };
                } else if let Some(v) = line.strip_prefix("serial_established=") {
                    serial_established = match v {
                        "0" => Some(false),
                        "1" => Some(true),
                        _ => return Err(()),
                    };
                }
            }
            match (lifetime_id, state, serial_established) {
                (Some(lifetime_id), Some(state), Some(serial_established)) => Ok(Some(SeatRecord {
                    lifetime_id,
                    state,
                    serial_established,
                })),
                _ => Err(()),
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(()),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WaitEpochOutcome {
    Confirmed,
    TimedOut,
    DriverClosedFailClosed,
}

async fn wait_epoch_confirmed(
    rx: &mut watch::Receiver<u64>,
    obligations: &Arc<Mutex<BridgeObligations>>,
    needed_epoch: u64,
    deadline: Instant,
) -> WaitEpochOutcome {
    match tokio::time::timeout_at(deadline, rx.wait_for(|&d| d >= needed_epoch)).await {
        Ok(Ok(guard)) => {
            let val = *guard;
            drop(guard);
            if val >= needed_epoch {
                WaitEpochOutcome::Confirmed
            } else {
                WaitEpochOutcome::TimedOut
            }
        }
        Ok(Err(_)) => {
            let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
            ob.recovery_gate = RecoveryGate::ExhaustedFailClosed;
            WaitEpochOutcome::DriverClosedFailClosed
        }
        Err(_) => WaitEpochOutcome::TimedOut,
    }
}

struct RecoveryDriver {
    floor_file: PathBuf,
    seat_file: PathBuf,
    lan_socket: Arc<tokio::net::UdpSocket>,
    lan_peer: SocketAddr,
    obligations: Arc<Mutex<BridgeObligations>>,
    recovery_notify: Arc<Notify>,
    active_slot: Arc<Mutex<ActiveRecoverySlot>>,
    completed_epoch_tx: watch::Sender<u64>,
    in_memory_floor: Option<u32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DriverStep {
    Confirmed,
    Retry,
    Exhausted,
}

impl RecoveryDriver {
    fn fail_closed(&mut self) -> DriverStep {
        let mut ob = self.obligations.lock().unwrap_or_else(|e| e.into_inner());
        ob.recovery_gate = RecoveryGate::ExhaustedFailClosed;
        DriverStep::Exhausted
    }

    async fn step_once(&mut self) -> DriverStep {
        let (attempt_epoch, buttons) = {
            let ob = self.obligations.lock().unwrap_or_else(|e| e.into_inner());
            match ob.recovery_gate {
                RecoveryGate::Healthy => return DriverStep::Confirmed,
                RecoveryGate::ExhaustedFailClosed => return DriverStep::Exhausted,
                RecoveryGate::RecoveryRequired { .. } => {
                    (ob.obligation_epoch, ob.pressed_buttons.clone())
                }
            }
        };

        let floor_res = read_floor_file(&self.floor_file);
        let seat_res = read_seat_file(&self.seat_file);

        let (floor, mut seat_established) = match (floor_res, seat_res) {
            (Ok(None), Ok(None)) => {
                // Rule 1: Native bootstrap uncommitted — write nothing, allocate no serial.
                return DriverStep::Retry;
            }
            (Ok(None), Ok(Some(seat))) => {
                // Rule 2: Only bootstrap floor=0 if in_memory_floor is None, serial_established == 0, and CLEAN.
                if self.in_memory_floor.is_some()
                    || seat.serial_established
                    || seat.state != SeatState::Clean
                {
                    return self.fail_closed();
                }
                if atomic_write_file(&self.floor_file, "floor=0\n").is_err() {
                    return self.fail_closed();
                }
                self.in_memory_floor = Some(0);
                (0, false)
            }
            (Ok(Some(_)), Ok(None)) => {
                // Rule 3: Unexpected native-seat loss -> permanent ExhaustedFailClosed.
                return self.fail_closed();
            }
            (Ok(Some(floor)), Ok(Some(seat))) => (floor, seat.serial_established),
            _ => return self.fail_closed(),
        };

        if !seat_established {
            // Rule 4: Pre-issuance barrier — floor must be 0, in_memory_floor in {None, Some(0)}.
            if floor != 0 || matches!(self.in_memory_floor, Some(prev) if prev != 0) {
                return self.fail_closed();
            }
            self.in_memory_floor = Some(0);
            // Send side-effect-free Ping [6] nudge and poll until serial_established == 1.
            let _ = self.lan_socket.send_to(&[PROTO_PING], self.lan_peer).await;
            let deadline = Instant::now() + RECOVERY_BUDGET;
            loop {
                tokio::time::sleep(RECOVERY_POLL_INTERVAL).await;
                match read_seat_file(&self.seat_file) {
                    Ok(Some(updated)) if updated.serial_established => {
                        seat_established = true;
                        break;
                    }
                    Ok(Some(_)) => {
                        if Instant::now() >= deadline {
                            return DriverStep::Retry;
                        }
                    }
                    _ => return self.fail_closed(),
                }
            }
        }
        let _ = seat_established;

        // Rule 5: serial_established == 1 -> verify floor < u32::MAX and no regression.
        if floor >= u32::MAX || matches!(self.in_memory_floor, Some(prev) if floor != prev) {
            return self.fail_closed();
        }
        let Some(next) = floor.checked_add(1) else {
            return self.fail_closed();
        };
        let Some(next_nz) = NonZeroU32::new(next) else {
            return self.fail_closed();
        };
        if atomic_write_file(&self.floor_file, &format!("floor={next}\n")).is_err() {
            return self.fail_closed();
        }
        self.in_memory_floor = Some(next);

        let (ack_tx, ack_rx) = oneshot::channel();
        {
            let mut slot = self
                .active_slot
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            slot.install(attempt_epoch, next_nz, ack_tx);
        }
        let _guard = RecoverySlotGuard {
            slot: self.active_slot.clone(),
        };

        for button in buttons {
            let rel = encode_button_release(button);
            if self.lan_socket.send_to(&rel, self.lan_peer).await.is_err() {
                return DriverStep::Retry;
            }
        }
        let leave = encode_control_frame(PROTO_LEAVE, next);
        if self
            .lan_socket
            .send_to(&leave, self.lan_peer)
            .await
            .is_err()
        {
            return DriverStep::Retry;
        }

        match tokio::time::timeout(RECOVERY_BUDGET, ack_rx).await {
            Ok(Ok(())) => {
                let mut ob = self.obligations.lock().unwrap_or_else(|e| e.into_inner());
                if ob.recovery_gate == RecoveryGate::ExhaustedFailClosed {
                    return DriverStep::Exhausted;
                }
                if ob.obligation_epoch == attempt_epoch {
                    ob.pressed_buttons.clear();
                    ob.has_active_obligations = false;
                    ob.recovery_gate = RecoveryGate::Healthy;
                    let _ = self.completed_epoch_tx.send_replace(attempt_epoch);
                    DriverStep::Confirmed
                } else {
                    DriverStep::Retry
                }
            }
            _ => DriverStep::Retry,
        }
    }

    async fn run(mut self, mut shutdown_rx: watch::Receiver<bool>) {
        loop {
            if *shutdown_rx.borrow() {
                break;
            }
            let needs_recovery = {
                let ob = self.obligations.lock().unwrap_or_else(|e| e.into_inner());
                matches!(ob.recovery_gate, RecoveryGate::RecoveryRequired { .. })
            };
            if !needs_recovery {
                tokio::select! {
                    biased;
                    _ = shutdown_rx.changed() => break,
                    _ = self.recovery_notify.notified() => continue,
                }
            }
            match self.step_once().await {
                DriverStep::Confirmed => continue,
                DriverStep::Exhausted => break,
                DriverStep::Retry => {
                    tokio::select! {
                        biased;
                        _ = shutdown_rx.changed() => break,
                        _ = tokio::time::sleep(RECOVERY_BACKOFF) => {}
                    }
                }
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SessionForwardTarget {
    session_gen: u64,
}

struct DemuxTarget {
    active_gen: Option<SessionForwardTarget>,
    refused_until: Option<Instant>,
    tx: Option<mpsc::Sender<Vec<u8>>>,
    cancel_tx: Option<watch::Sender<bool>>,
}

async fn run_local_udp_demux(
    lan_socket: Arc<tokio::net::UdpSocket>,
    expected_peer: SocketAddr,
    active_slot: Arc<Mutex<ActiveRecoverySlot>>,
    demux_target: Arc<Mutex<DemuxTarget>>,
    mut shutdown_rx: watch::Receiver<bool>,
) {
    let mut buf = [0u8; 2048];
    loop {
        tokio::select! {
            biased;
            _ = shutdown_rx.changed() => break,
            recv = lan_socket.recv_from(&mut buf) => {
                let Ok((len, from)) = recv else {
                    continue;
                };
                if from != expected_peer {
                    continue;
                }
                let payload = &buf[..len];
                let Ok(kind) = validate_d5_frame(payload) else {
                    continue;
                };
                if let FrameKind::Ack(serial) = kind {
                    if serial != 0 {
                        let mut slot = active_slot.lock().unwrap_or_else(|e| e.into_inner());
                        slot.deliver_ack(serial);
                        continue;
                    }
                }
                let (tx_opt, cancel_opt) = {
                    let guard = demux_target.lock().unwrap_or_else(|e| e.into_inner());
                    if guard.refused_until.is_some_and(|until| Instant::now() < until) {
                        continue;
                    }
                    if guard.active_gen.is_none() {
                        continue;
                    }
                    (guard.tx.clone(), guard.cancel_tx.clone())
                };
                if let Some(tx) = tx_opt {
                    if let Err(mpsc::error::TrySendError::Full(_)) = tx.try_send(payload.to_vec()) {
                        if kind.is_stateful() {
                            if let Some(cancel) = cancel_opt {
                                let _ = cancel.send(true);
                            }
                        }
                    }
                }
            }
        }
    }
}

#[derive(Clone, Debug)]
struct NiriSessionConfig {
    niri_bin: PathBuf,
    busctl_bin: PathBuf,
    niri_socket: PathBuf,
    enter_output: String,
    #[cfg(test)]
    test_placement_hold: Option<Arc<Mutex<Option<(oneshot::Sender<()>, std::sync::mpsc::Receiver<()>)>>>>,
}

fn current_euid() -> io::Result<u32> {
    let status = std::fs::read_to_string("/proc/self/status")?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("Uid:") {
            let mut cols = rest.split_whitespace();
            let _real = cols.next();
            if let Some(euid) = cols.next() {
                return euid
                    .parse::<u32>()
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e));
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "Uid missing in /proc/self/status",
    ))
}

async fn run_bounded_command(
    program: &Path,
    args: &[&str],
    envs: &[(&str, &str)],
    obligations: &Arc<Mutex<BridgeObligations>>,
    deadline: Instant,
) -> Result<String, &'static str> {
    {
        let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
        if !ob.reserve_reaper_slot() {
            return Err("reaper saturated");
        }
    }
    let (read_std, write_std) = match StdUnixStream::pair() {
        Ok(pair) => pair,
        Err(_) => {
            let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
            ob.reserved_reaper_slots = ob.reserved_reaper_slots.saturating_sub(1);
            return Err("unix pair failed");
        }
    };
    if read_std.set_nonblocking(true).is_err() {
        let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
        ob.reserved_reaper_slots = ob.reserved_reaper_slots.saturating_sub(1);
        return Err("set_nonblocking failed");
    }

    let mut cmd = Command::new(program);
    cmd.args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .stdout(Stdio::from(std::os::fd::OwnedFd::from(write_std)));
    for (k, v) in envs {
        cmd.env(k, v);
    }
    let child = match cmd.spawn() {
        Ok(c) => c,
        Err(_) => {
            let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
            ob.reserved_reaper_slots = ob.reserved_reaper_slots.saturating_sub(1);
            return Err("command spawn failed");
        }
    };
    let mut guard = SpawnedChildGuard::new(child, obligations.clone());
    // Drop `cmd` immediately so the parent's copy of the write-end stdout fd closes.
    drop(cmd);
    let mut tokio_read =
        tokio::net::UnixStream::from_std(read_std).map_err(|_| "tokio unix stream failed")?;

    let mut out = Vec::with_capacity(4096);
    let mut chunk = [0u8; 4096];
    let mut eof = false;
    let mut exit_status = None;

    loop {
        if Instant::now() >= deadline {
            return Err("command deadline expired");
        }
        if !eof {
            tokio::select! {
                biased;
                res = tokio::time::timeout_at(deadline, tokio_read.read(&mut chunk)) => {
                    match res {
                        Ok(Ok(0)) => eof = true,
                        Ok(Ok(n)) => {
                            if out.len() + n > MAX_COMMAND_STDOUT_BYTES {
                                return Err("command stdout exceeded 64 KiB");
                            }
                            out.extend_from_slice(&chunk[..n]);
                        }
                        Ok(Err(e)) if e.kind() == io::ErrorKind::Interrupted => {}
                        Ok(Err(_)) => return Err("command stdout read failed"),
                        Err(_) => return Err("command deadline expired"),
                    }
                }
                _ = tokio::time::sleep(Duration::from_millis(5)) => {}
            }
        } else {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }

        if exit_status.is_none() {
            match guard.try_wait() {
                Ok(Some(status)) => exit_status = Some(status),
                Ok(None) => {}
                Err(_) => return Err("try_wait failed"),
            }
        }
        if eof && exit_status.is_some() {
            break;
        }
    }

    if !exit_status.is_some_and(|s| s.success()) {
        return Err("command exited non-zero");
    }
    String::from_utf8(out).map_err(|_| "command stdout not utf-8")
}

fn parse_busctl_object_path(output: &str) -> Option<String> {
    let start = output.find('"')? + 1;
    let end = output[start..].find('"')? + start;
    let path = &output[start..end];
    if path.starts_with("/org/freedesktop/login1/session/") {
        Some(path.to_string())
    } else {
        None
    }
}

fn parse_busctl_user_uid(output: &str) -> Option<u32> {
    let mut tokens = output.split_whitespace();
    let sig = tokens.next()?;
    if sig != "(uo)" {
        return None;
    }
    tokens.next()?.parse::<u32>().ok()
}

struct JsonStr<'de>(std::borrow::Cow<'de, str>);

impl<'de> serde::Deserialize<'de> for JsonStr<'de> {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct StrVisitor;
        impl<'de> serde::de::Visitor<'de> for StrVisitor {
            type Value = JsonStr<'de>;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("a JSON string")
            }
            fn visit_borrowed_str<E: serde::de::Error>(
                self,
                v: &'de str,
            ) -> Result<Self::Value, E> {
                Ok(JsonStr(std::borrow::Cow::Borrowed(v)))
            }
            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Self::Value, E> {
                Ok(JsonStr(std::borrow::Cow::Owned(v.to_owned())))
            }
            fn visit_string<E: serde::de::Error>(self, v: String) -> Result<Self::Value, E> {
                Ok(JsonStr(std::borrow::Cow::Owned(v)))
            }
        }
        deserializer.deserialize_str(StrVisitor)
    }
}

macro_rules! strict_json_string_enum {
    ($( enum $name:ident { $( $variant:ident => $lit:literal ),+ $(,)? } )+) => {
        $(
            #[allow(dead_code)]
            #[derive(Debug, Clone, Copy, PartialEq, Eq)]
            enum $name { $( $variant, )+ }

            impl<'de> serde::Deserialize<'de> for $name {
                fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                    const VARIANTS: &'static [&'static str] = &[ $( $lit ),+ ];
                    let s = JsonStr::deserialize(deserializer)?;
                    match s.0.as_ref() {
                        $( $lit => Ok(Self::$variant), )+
                        other => Err(serde::de::Error::unknown_variant(other, VARIANTS)),
                    }
                }
            }
        )+
    };
}

macro_rules! strict_json_object_dto {
    ($( struct $name:ident { $( $field:ident : $ty:ty ),+ $(,)? } )+) => {
        $(
            #[allow(dead_code)]
            #[derive(Debug, Clone, PartialEq)]
            struct $name { $( $field: $ty, )+ }

            impl<'de> serde::Deserialize<'de> for $name {
                fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                    const FIELDS: &'static [&'static str] = &[ $( stringify!($field) ),+ ];
                    struct ObjectVisitor;
                    impl<'de> serde::de::Visitor<'de> for ObjectVisitor {
                        type Value = $name;
                        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                            f.write_str(concat!("JSON object for ", stringify!($name)))
                        }
                        fn visit_map<A: serde::de::MapAccess<'de>>(
                            self,
                            mut map: A,
                        ) -> Result<Self::Value, A::Error> {
                            $( let mut $field: Option<$ty> = None; )+
                            while let Some(key) = map.next_key::<JsonStr<'de>>()? {
                                match key.0.as_ref() {
                                    $(
                                        stringify!($field) => {
                                            if $field.is_some() {
                                                return Err(serde::de::Error::duplicate_field(
                                                    stringify!($field),
                                                ));
                                            }
                                            $field = Some(map.next_value::<$ty>()?);
                                        }
                                    )+
                                    unknown => {
                                        return Err(serde::de::Error::unknown_field(unknown, FIELDS));
                                    }
                                }
                            }
                            Ok($name {
                                $(
                                    $field: $field.ok_or_else(|| {
                                        serde::de::Error::missing_field(stringify!($field))
                                    })?,
                                )+
                            })
                        }
                    }
                    deserializer.deserialize_map(ObjectVisitor)
                }
            }
        )+
    };
}

strict_json_string_enum! {
    enum TransformDto {
        Normal => "Normal",
        _90 => "90",
        _180 => "180",
        _270 => "270",
        Flipped => "Flipped",
        Flipped90 => "Flipped90",
        Flipped180 => "Flipped180",
        Flipped270 => "Flipped270",
    }
    enum LayerDto {
        Background => "Background",
        Bottom => "Bottom",
        Top => "Top",
        Overlay => "Overlay",
    }
    enum LayerKeyboardInteractivityDto {
        None => "None",
        Exclusive => "Exclusive",
        OnDemand => "OnDemand",
    }
}

strict_json_object_dto! {
    struct OverviewDto {
        is_open: bool,
    }
    struct ModeDto {
        width: u16,
        height: u16,
        refresh_rate: u32,
        is_preferred: bool,
    }
    struct LogicalOutputDto {
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        scale: f64,
        transform: TransformDto,
    }
    struct OutputDto {
        name: String,
        make: String,
        model: String,
        serial: Option<String>,
        physical_size: Option<(u32, u32)>,
        modes: Vec<ModeDto>,
        current_mode: Option<usize>,
        is_custom_mode: bool,
        vrr_supported: bool,
        vrr_enabled: bool,
        logical: Option<LogicalOutputDto>,
    }
    struct LayerSurfaceDto {
        namespace: String,
        output: String,
        layer: LayerDto,
        keyboard_interactivity: LayerKeyboardInteractivityDto,
    }
    struct WorkspaceDto {
        id: u64,
        idx: u8,
        name: Option<String>,
        output: Option<String>,
        is_urgent: bool,
        is_active: bool,
        is_focused: bool,
        active_window_id: Option<u64>,
    }
    struct TimestampDto {
        secs: u64,
        nanos: u32,
    }
    struct WindowLayoutDto {
        pos_in_scrolling_layout: Option<(usize, usize)>,
        tile_size: (f64, f64),
        window_size: (i32, i32),
        tile_pos_in_workspace_view: Option<(f64, f64)>,
        window_offset_in_tile: (f64, f64),
    }
    struct WindowDto {
        id: u64,
        title: Option<String>,
        app_id: Option<String>,
        pid: Option<i32>,
        workspace_id: Option<u64>,
        is_focused: bool,
        is_floating: bool,
        is_urgent: bool,
        layout: WindowLayoutDto,
        focus_timestamp: Option<TimestampDto>,
    }
}

fn parse_focused_output_json(raw: &str, expected_output: &str) -> bool {
    let Ok(Some(out)) = serde_json::from_str::<Option<OutputDto>>(raw) else {
        return false;
    };
    if out.name != expected_output {
        return false;
    }
    if !out.current_mode.is_none_or(|idx| idx < out.modes.len()) {
        return false;
    }
    out.logical
        .as_ref()
        .is_some_and(|l| l.width > 0 && l.height > 0 && l.scale.is_finite() && l.scale > 0.0)
}

fn parse_layers_allows_entry_json(raw: &str) -> bool {
    let Ok(surfaces) = serde_json::from_str::<Vec<LayerSurfaceDto>>(raw) else {
        return false;
    };
    if !surfaces.iter().all(|s| !s.output.is_empty()) {
        return false;
    }
    !surfaces.iter().any(|s| {
        s.keyboard_interactivity == LayerKeyboardInteractivityDto::Exclusive
            && s.namespace != "LAN Mouse Sharing"
    })
}

fn check_workspace_and_focus_allows_entry_json(
    workspaces_raw: &str,
    windows_raw: &str,
    overview_raw: &str,
    focused_win_raw: &str,
    expected_output: &str,
) -> bool {
    let Ok(overview) = serde_json::from_str::<OverviewDto>(overview_raw) else {
        return false;
    };
    let Ok(workspaces) = serde_json::from_str::<Vec<WorkspaceDto>>(workspaces_raw) else {
        return false;
    };
    let Ok(windows) = serde_json::from_str::<Vec<WindowDto>>(windows_raw) else {
        return false;
    };
    let Ok(focused_window) = serde_json::from_str::<Option<WindowDto>>(focused_win_raw) else {
        return false;
    };

    if workspaces.is_empty() {
        return false;
    }

    let mut seen_ws_ids = BTreeSet::new();
    let mut seen_non_sat_output_idx = BTreeSet::new();
    for ws in &workspaces {
        if ws.idx < 1 {
            return false;
        }
        if ws.output.as_deref() == Some("") {
            return false;
        }
        if !seen_ws_ids.insert(ws.id) {
            return false;
        }
        if ws.idx < u8::MAX && !seen_non_sat_output_idx.insert((ws.output.as_deref(), ws.idx)) {
            return false;
        }
    }

    if workspaces.iter().filter(|w| w.is_focused).count() > 1 {
        return false;
    }

    let mut target_matches = workspaces
        .iter()
        .filter(|w| w.output.as_deref() == Some(expected_output) && w.is_active);
    let Some(target_ws) = target_matches.next() else {
        return false;
    };
    if target_matches.next().is_some() || !target_ws.is_focused {
        return false;
    }
    if workspaces
        .iter()
        .any(|w| w.output.as_deref() == Some(expected_output) && !w.is_active && w.is_focused)
    {
        return false;
    }

    let mut seen_win_ids = BTreeSet::new();
    for w in &windows {
        if !seen_win_ids.insert(w.id) {
            return false;
        }
        if let Some(wid) = w.workspace_id {
            if !seen_ws_ids.contains(&wid) {
                return false;
            }
        }
        if let Some(ts) = &w.focus_timestamp {
            if ts.nanos >= 1_000_000_000 {
                return false;
            }
        }
    }
    if windows.iter().filter(|w| w.is_focused).count() > 1 {
        return false;
    }
    if let Some(ref fw) = focused_window {
        if !fw.is_focused {
            return false;
        }
        if let Some(wid) = fw.workspace_id {
            if !seen_ws_ids.contains(&wid) {
                return false;
            }
        }
        if let Some(ts) = &fw.focus_timestamp {
            if ts.nanos >= 1_000_000_000 {
                return false;
            }
        }
    }

    if overview.is_open {
        return focused_window
            .as_ref()
            .is_none_or(|fw| fw.workspace_id == Some(target_ws.id));
    }

    let target_windows: Vec<&WindowDto> = windows
        .iter()
        .filter(|w| w.workspace_id == Some(target_ws.id))
        .collect();
    if !target_windows.is_empty() {
        let Some(fw) = focused_window else {
            return false;
        };
        fw.workspace_id == Some(target_ws.id)
            && target_windows.iter().any(|w| w.id == fw.id)
            && windows.iter().filter(|w| w.is_focused).all(|w| w.id == fw.id)
            && windows.iter().any(|w| w.is_focused && w.id == fw.id)
            && target_ws.active_window_id == Some(fw.id)
    } else {
        target_ws.active_window_id.is_none()
            && focused_window.is_none()
            && windows.iter().all(|w| !w.is_focused)
            && windows.iter().all(|w| w.workspace_id.is_some())
    }
}

async fn verify_and_place_output(
    cfg: &NiriSessionConfig,
    obligations: &Arc<Mutex<BridgeObligations>>,
) -> Result<(), &'static str> {
    #[cfg(test)]
    if let Some(hold) = &cfg.test_placement_hold {
        if let Some((started_tx, release_rx)) = hold.lock().unwrap().take() {
            let _ = started_tx.send(());
            let _ = release_rx.recv_timeout(Duration::from_millis(800));
        }
    }
    let deadline = Instant::now() + PLACEMENT_BUDGET;
    let sock_stream =
        tokio::time::timeout_at(deadline, tokio::net::UnixStream::connect(&cfg.niri_socket))
            .await
            .map_err(|_| "connect NIRI_SOCKET timed out")?
            .map_err(|_| "connect NIRI_SOCKET failed")?;
    let cred = sock_stream
        .peer_cred()
        .map_err(|_| "NIRI_SOCKET peer_cred failed")?;
    let euid = current_euid().map_err(|_| "geteuid failed")?;
    if cred.uid() != euid {
        return Err("NIRI_SOCKET peer uid mismatch");
    }
    let pid = cred
        .pid()
        .filter(|&p| p > 0)
        .ok_or("NIRI_SOCKET missing peer pid")?;
    let pid_str = pid.to_string();
    let niri_sock_str = cfg.niri_socket.to_str().ok_or("invalid NIRI_SOCKET")?;

    let session_out = run_bounded_command(
        &cfg.busctl_bin,
        &[
            "--system",
            "call",
            "org.freedesktop.login1",
            "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager",
            "GetSessionByPID",
            "u",
            &pid_str,
        ],
        &[],
        obligations,
        deadline,
    )
    .await?;
    let session_path = parse_busctl_object_path(&session_out).ok_or("invalid session path")?;

    let user_prop = run_bounded_command(
        &cfg.busctl_bin,
        &[
            "--system",
            "get-property",
            "org.freedesktop.login1",
            &session_path,
            "org.freedesktop.login1.Session",
            "User",
        ],
        &[],
        obligations,
        deadline,
    )
    .await?;
    if parse_busctl_user_uid(&user_prop) != Some(euid) {
        return Err("logind session User mismatch");
    }

    for (prop, expected) in [
        ("Active", "b true"),
        ("State", "s \"active\""),
        ("Type", "s \"wayland\""),
        ("Class", "s \"user\""),
        ("LockedHint", "b false"),
    ] {
        let val = run_bounded_command(
            &cfg.busctl_bin,
            &[
                "--system",
                "get-property",
                "org.freedesktop.login1",
                &session_path,
                "org.freedesktop.login1.Session",
                prop,
            ],
            &[],
            obligations,
            deadline,
        )
        .await?;
        if val.trim() != expected {
            return Err("logind session property check failed");
        }
    }

    let niri_env = [("NIRI_SOCKET", niri_sock_str)];
    let action_out = run_bounded_command(
        &cfg.niri_bin,
        &["msg", "action", "focus-monitor", &cfg.enter_output],
        &niri_env,
        obligations,
        deadline,
    )
    .await?;
    if !action_out.trim().is_empty() {
        return Err("focus-monitor unexpected stdout");
    }

    let focused_out = run_bounded_command(
        &cfg.niri_bin,
        &["msg", "--json", "focused-output"],
        &niri_env,
        obligations,
        deadline,
    )
    .await?;
    if !parse_focused_output_json(&focused_out, &cfg.enter_output) {
        return Err("focused-output mismatch");
    }

    let layers_out = run_bounded_command(
        &cfg.niri_bin,
        &["msg", "--json", "layers"],
        &niri_env,
        obligations,
        deadline,
    )
    .await?;
    if !parse_layers_allows_entry_json(&layers_out) {
        return Err("exclusive overlay blocks entry");
    }

    let workspaces_out = run_bounded_command(
        &cfg.niri_bin,
        &["msg", "--json", "workspaces"],
        &niri_env,
        obligations,
        deadline,
    )
    .await?;
    let windows_out = run_bounded_command(
        &cfg.niri_bin,
        &["msg", "--json", "windows"],
        &niri_env,
        obligations,
        deadline,
    )
    .await?;
    let overview_out = run_bounded_command(
        &cfg.niri_bin,
        &["msg", "--json", "overview-state"],
        &niri_env,
        obligations,
        deadline,
    )
    .await?;
    let focused_win_out = run_bounded_command(
        &cfg.niri_bin,
        &["msg", "--json", "focused-window"],
        &niri_env,
        obligations,
        deadline,
    )
    .await?;

    if !check_workspace_and_focus_allows_entry_json(
        &workspaces_out,
        &windows_out,
        &overview_out,
        &focused_win_out,
        &cfg.enter_output,
    ) {
        return Err("non-empty workspace lacks focused window");
    }

    Ok(())
}

enum EntryState {
    Idle,
    PendingPlacement {
        entry_id: u64,
        enter_frame: Vec<u8>,
        buffered: VecDeque<Vec<u8>>,
    },
    Placed {
        placed_at: Instant,
        last_activity: Instant,
        input_seen: bool,
    },
    Refused {
        until: Instant,
    },
}

fn main() {
    if let Err(err) = run() {
        eprintln!("cursor-bridge: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error + Send + Sync>> {
    let args = parse(std::env::args().skip(1))?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(serve(args))
}

struct LatestConnSlot {
    closed: bool,
    pending: Option<Connection>,
}

impl LatestConnSlot {
    fn publish(&mut self, conn: Connection) {
        if self.closed {
            conn.close(1u32.into(), b"shutdown");
            return;
        }
        if let Some(old) = self.pending.replace(conn) {
            old.close(1u32.into(), b"superseded_unconsumed");
        }
    }

    fn take(&mut self) -> Option<Connection> {
        if self.closed {
            None
        } else {
            self.pending.take()
        }
    }

    fn seal_and_close(&mut self) {
        self.closed = true;
        if let Some(conn) = self.pending.take() {
            conn.close(1u32.into(), b"shutdown");
        }
    }
}

async fn send_quic_frame(
    connection: &Connection,
    payload: &[u8],
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let mut stream = connection.open_uni().await?;
    let _ = stream.set_priority(10);
    let mut framed = Vec::with_capacity(1 + payload.len());
    framed.push(payload.len() as u8);
    framed.extend_from_slice(payload);
    stream.write_all(&framed).await?;
    stream.finish()?;
    Ok(())
}

async fn wait_for_healthy_before_input(
    obligations: &Arc<Mutex<BridgeObligations>>,
    completed_epoch_rx: &mut watch::Receiver<u64>,
    budget: Duration,
) -> Result<(), &'static str> {
    let needed = {
        let ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
        match ob.recovery_gate {
            RecoveryGate::Healthy => return Ok(()),
            RecoveryGate::ExhaustedFailClosed => return Err("exhausted_fail_closed"),
            RecoveryGate::RecoveryRequired { required_epoch } => required_epoch,
        }
    };
    let deadline = Instant::now() + budget;
    match wait_epoch_confirmed(completed_epoch_rx, obligations, needed, deadline).await {
        WaitEpochOutcome::Confirmed => Ok(()),
        WaitEpochOutcome::TimedOut => Err("recovery_unconfirmed"),
        WaitEpochOutcome::DriverClosedFailClosed => Err("exhausted_fail_closed"),
    }
}

struct SpliceHandles {
    inbound: Option<tokio::task::JoinHandle<()>>,
    outbound: Option<tokio::task::JoinHandle<()>>,
    clipboard: Option<tokio::task::JoinHandle<()>>,
    placement_slot: Arc<tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>>,
    conn: Connection,
    cancel_tx: watch::Sender<bool>,
}

struct PlacementAbortOnDrop(Arc<tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>>);

impl Drop for PlacementAbortOnDrop {
    fn drop(&mut self) {
        if let Ok(guard) = self.0.try_lock() {
            if let Some(h) = guard.as_ref() {
                h.abort();
            }
        }
    }
}

async fn cancel_and_join_placement(
    placement_rx: &mut Option<(u64, oneshot::Receiver<Result<(), &'static str>>)>,
    placement_slot: &Arc<tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>>,
) {
    *placement_rx = None;
    let mut guard = placement_slot.lock().await;
    if let Some(h) = guard.as_mut() {
        h.abort();
        let _ = (&mut *h).await;
        *guard = None;
    }
}

async fn await_optional_pair(
    a: &mut Option<tokio::task::JoinHandle<()>>,
    b: &mut Option<tokio::task::JoinHandle<()>>,
) {
    let mut none = None;
    await_optional_triple(a, b, &mut none).await;
}

async fn await_optional_triple(
    a: &mut Option<tokio::task::JoinHandle<()>>,
    b: &mut Option<tokio::task::JoinHandle<()>>,
    c: &mut Option<tokio::task::JoinHandle<()>>,
) {
    while a.is_some() || b.is_some() || c.is_some() {
        tokio::select! {
            res = async {
                if let Some(h) = a.as_mut() {
                    h.await
                } else {
                    std::future::pending().await
                }
            }, if a.is_some() => {
                let _ = res;
                *a = None;
            }
            res = async {
                if let Some(h) = b.as_mut() {
                    h.await
                } else {
                    std::future::pending().await
                }
            }, if b.is_some() => {
                let _ = res;
                *b = None;
            }
            res = async {
                if let Some(h) = c.as_mut() {
                    h.await
                } else {
                    std::future::pending().await
                }
            }, if c.is_some() => {
                let _ = res;
                *c = None;
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn spawn_splice_tasks(
    connection: Connection,
    lan_socket: Arc<tokio::net::UdpSocket>,
    lan_peer: SocketAddr,
    niri_cfg: Option<NiriSessionConfig>,
    obligations: Arc<Mutex<BridgeObligations>>,
    recovery_notify: Arc<Notify>,
    mut completed_epoch_rx: watch::Receiver<u64>,
    mut local_to_quic_rx: mpsc::Receiver<Vec<u8>>,
    demux_target: Arc<Mutex<DemuxTarget>>,
    cancel_rx: watch::Receiver<bool>,
    placement_slot: Arc<tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>>,
) -> (
    tokio::task::JoinHandle<()>,
    tokio::task::JoinHandle<()>,
) {
    let out_conn = connection.clone();
    let out_cancel = cancel_rx.clone();
    let out_demux = demux_target.clone();
    let out_ob = obligations.clone();
    let out_notify = recovery_notify.clone();
    let out_epoch_rx = completed_epoch_rx.clone();

    let outbound_handle = tokio::spawn(async move {
        let mut cancel = out_cancel;
        loop {
            tokio::select! {
                biased;
                _ = cancel.changed() => break,
                maybe_frame = local_to_quic_rx.recv() => {
                    let Some(frame) = maybe_frame else { break; };
                    let refused = {
                        let guard = out_demux.lock().unwrap_or_else(|e| e.into_inner());
                        guard.refused_until.is_some_and(|until| Instant::now() < until)
                    };
                    if refused {
                        continue;
                    }
                    if let Ok(FrameKind::Enter(_)) = validate_d5_frame(&frame) {
                        let needs_rec = {
                            let mut ob = out_ob.lock().unwrap_or_else(|e| e.into_inner());
                            if ob.has_active_obligations {
                                Some(ob.trigger_recovery(&out_notify))
                            } else {
                                None
                            }
                        };
                        if let Some(needed) = needs_rec {
                            let deadline = Instant::now() + CALLER_RECOVERY_WAIT_BUDGET;
                            let mut rx = out_epoch_rx.clone();
                            if wait_epoch_confirmed(&mut rx, &out_ob, needed, deadline).await != WaitEpochOutcome::Confirmed {
                                out_conn.close(5u32.into(), b"recovery_unconfirmed");
                                break;
                            }
                        }
                    }
                    if send_quic_frame(&out_conn, &frame).await.is_err() {
                        break;
                    }
                }
            }
        }
    });

    let in_conn = connection;
    let in_cancel = cancel_rx;
    let inbound_handle = tokio::spawn(async move {
        let mut cancel = in_cancel;
        let _placement_drop_guard = PlacementAbortOnDrop(placement_slot.clone());
        let mut entry_state = EntryState::Idle;
        let mut entry_seq: u64 = 0;
        let mut placement_rx: Option<(u64, oneshot::Receiver<Result<(), &'static str>>)> = None;
        let mut consecutive_drops: usize = 0;

        loop {
            if *cancel.borrow() {
                cancel_and_join_placement(&mut placement_rx, &placement_slot).await;
                break;
            }

            let idle_sleep_until = match &entry_state {
                EntryState::Placed { last_activity, .. } => Some(*last_activity + IDLE_CAPTURE_TIMEOUT),
                EntryState::Refused { until } => Some(*until),
                _ => None,
            };

            enum InboundEvent {
                Cancelled,
                PlacementDone(u64, Result<(), &'static str>),
                TimerExpired,
                Stream(Result<quinn::RecvStream, quinn::ConnectionError>),
            }

            let ev = tokio::select! {
                biased;
                _ = cancel.changed() => InboundEvent::Cancelled,
                res = async {
                    if let Some((pid, rx)) = &mut placement_rx {
                        let id = *pid;
                        match rx.await {
                            Ok(r) => (id, r),
                            Err(_) => (id, Err("placement task dropped")),
                        }
                    } else {
                        std::future::pending().await
                    }
                }, if placement_rx.is_some() => InboundEvent::PlacementDone(res.0, res.1),
                _ = async {
                    if let Some(deadline) = idle_sleep_until {
                        tokio::time::sleep_until(deadline).await;
                    } else {
                        std::future::pending::<()>().await;
                    }
                }, if idle_sleep_until.is_some() => InboundEvent::TimerExpired,
                accepted = in_conn.accept_uni() => InboundEvent::Stream(accepted),
            };

            let stream_res = match ev {
                InboundEvent::Cancelled => {
                    cancel_and_join_placement(&mut placement_rx, &placement_slot).await;
                    break;
                }
                InboundEvent::PlacementDone(done_id, result) => {
                    placement_rx = None;
                    {
                        let mut guard = placement_slot.lock().await;
                        if let Some(h) = guard.as_mut() {
                            let _ = (&mut *h).await;
                            *guard = None;
                        }
                    }
                    if let EntryState::PendingPlacement {
                        entry_id,
                        enter_frame,
                        mut buffered,
                    } = std::mem::replace(&mut entry_state, EntryState::Idle)
                    {
                        if done_id != entry_id {
                            entry_state = EntryState::PendingPlacement {
                                entry_id,
                                enter_frame,
                                buffered,
                            };
                        } else if result.is_ok() {
                            if let Ok(enter_kind) = validate_d5_frame(&enter_frame) {
                                {
                                    let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                                    ob.record_obligation(enter_kind);
                                }
                                if lan_socket.send_to(&enter_frame, lan_peer).await.is_err() {
                                    break;
                                }
                            }
                            let mut send_failed = false;
                            let mut delivered_any_input = false;
                            while let Some(frame) = buffered.pop_front() {
                                if *cancel.borrow() {
                                    send_failed = true;
                                    break;
                                }
                                if let Ok(fk) = validate_d5_frame(&frame) {
                                    {
                                        let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                                        ob.record_obligation(fk);
                                    }
                                    if lan_socket.send_to(&frame, lan_peer).await.is_err() {
                                        send_failed = true;
                                        break;
                                    }
                                    delivered_any_input = true;
                                    if let FrameKind::PointerButton {
                                        button,
                                        pressed: false,
                                    } = fk
                                    {
                                        let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                                        ob.clear_released_button(button);
                                    }
                                }
                            }
                            if send_failed {
                                break;
                            }
                            let now = Instant::now();
                            entry_state = EntryState::Placed {
                                placed_at: now,
                                last_activity: now,
                                input_seen: delivered_any_input,
                            };
                        } else {
                            buffered.clear();
                            let until = Instant::now() + REFUSAL_QUIET_WINDOW;
                            {
                                let mut guard = demux_target.lock().unwrap_or_else(|e| e.into_inner());
                                guard.refused_until = Some(until);
                            }
                            entry_state = EntryState::Refused { until };
                        }
                    }
                    continue;
                }
                InboundEvent::TimerExpired => {
                    match entry_state {
                        EntryState::Placed { .. } => {
                            let needed = {
                                let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                                if ob.has_active_obligations {
                                    Some(ob.trigger_recovery(&recovery_notify))
                                } else {
                                    None
                                }
                            };
                            if let Some(epoch) = needed {
                                let deadline = Instant::now() + CALLER_RECOVERY_WAIT_BUDGET;
                                if wait_epoch_confirmed(&mut completed_epoch_rx, &obligations, epoch, deadline).await != WaitEpochOutcome::Confirmed {
                                    in_conn.close(5u32.into(), b"recovery_unconfirmed");
                                    break;
                                }
                            } else {
                                let _ = lan_socket.send_to(&encode_control_frame(PROTO_LEAVE, 0), lan_peer).await;
                            }
                            entry_state = EntryState::Idle;
                        }
                        EntryState::Refused { .. } => {
                            let mut guard = demux_target.lock().unwrap_or_else(|e| e.into_inner());
                            guard.refused_until = None;
                            entry_state = EntryState::Idle;
                        }
                        _ => {}
                    }
                    continue;
                }
                InboundEvent::Stream(accepted) => accepted,
            };

            let mut stream = match stream_res {
                Ok(s) => s,
                Err(_) => {
                    cancel_and_join_placement(&mut placement_rx, &placement_slot).await;
                    break;
                }
            };

            let read_res = tokio::time::timeout(FRAME_READ_TIMEOUT, stream.read_to_end(22)).await;
            let bytes = match read_res {
                Ok(Ok(b)) => b,
                _ => {
                    let _ = stream.stop(0u32.into());
                    consecutive_drops += 1;
                    let needed = {
                        let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                        ob.trigger_recovery(&recovery_notify)
                    };
                    let deadline = Instant::now() + CALLER_RECOVERY_WAIT_BUDGET;
                    if wait_epoch_confirmed(&mut completed_epoch_rx, &obligations, needed, deadline)
                        .await
                        != WaitEpochOutcome::Confirmed
                    {
                        in_conn.close(5u32.into(), b"recovery_unconfirmed");
                        break;
                    }
                    if consecutive_drops >= MAX_CONSECUTIVE_STREAM_DROPS {
                        in_conn.close(4u32.into(), b"stream_stall");
                        break;
                    }
                    continue;
                }
            };

            let payload = if bytes.len() >= 2 && bytes.len() == 1 + bytes[0] as usize && bytes[0] as usize <= EVENT_SIZE {
                &bytes[1..]
            } else {
                let _ = stream.stop(0u32.into());
                consecutive_drops += 1;
                let needed = {
                    let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                    ob.trigger_recovery(&recovery_notify)
                };
                let deadline = Instant::now() + CALLER_RECOVERY_WAIT_BUDGET;
                if wait_epoch_confirmed(&mut completed_epoch_rx, &obligations, needed, deadline)
                    .await
                    != WaitEpochOutcome::Confirmed
                {
                    in_conn.close(5u32.into(), b"recovery_unconfirmed");
                    break;
                }
                if consecutive_drops >= MAX_CONSECUTIVE_STREAM_DROPS {
                    in_conn.close(4u32.into(), b"stream_stall");
                    break;
                }
                continue;
            };

            let Ok(kind) = validate_d5_frame(payload) else {
                let _ = stream.stop(0u32.into());
                consecutive_drops += 1;
                let needed = {
                    let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                    ob.trigger_recovery(&recovery_notify)
                };
                let deadline = Instant::now() + CALLER_RECOVERY_WAIT_BUDGET;
                if wait_epoch_confirmed(&mut completed_epoch_rx, &obligations, needed, deadline)
                    .await
                    != WaitEpochOutcome::Confirmed
                {
                    in_conn.close(5u32.into(), b"recovery_unconfirmed");
                    break;
                }
                if consecutive_drops >= MAX_CONSECUTIVE_STREAM_DROPS {
                    in_conn.close(4u32.into(), b"stream_stall");
                    break;
                }
                continue;
            };
            consecutive_drops = 0;

            if matches!(kind, FrameKind::Ping | FrameKind::Pong) {
                if let EntryState::Placed { last_activity, .. } = &mut entry_state {
                    *last_activity = Instant::now();
                }
                if !matches!(entry_state, EntryState::Refused { .. }) {
                    let _ = lan_socket.send_to(payload, lan_peer).await;
                }
                continue;
            }

            if let Some(cfg) = &niri_cfg {
                match (&mut entry_state, kind) {
                    (EntryState::Refused { .. }, FrameKind::Leave(_)) => {
                        let mut guard = demux_target.lock().unwrap_or_else(|e| e.into_inner());
                        guard.refused_until = None;
                        entry_state = EntryState::Idle;
                        continue;
                    }
                    (EntryState::Refused { .. }, _) => {
                        continue;
                    }
                    (EntryState::Idle, FrameKind::Enter(_)) => {
                        if wait_for_healthy_before_input(
                            &obligations,
                            &mut completed_epoch_rx,
                            CALLER_RECOVERY_WAIT_BUDGET,
                        )
                        .await
                        .is_err()
                        {
                            in_conn.close(5u32.into(), b"recovery_unconfirmed");
                            break;
                        }
                        cancel_and_join_placement(&mut placement_rx, &placement_slot).await;
                        entry_seq += 1;
                        let eid = entry_seq;
                        let (ptx, prx) = oneshot::channel();
                        let cfg_clone = cfg.clone();
                        let ob_clone = obligations.clone();
                        let ph = tokio::spawn(async move {
                            let res = verify_and_place_output(&cfg_clone, &ob_clone).await;
                            let _ = ptx.send(res);
                        });
                        *placement_slot.lock().await = Some(ph);
                        placement_rx = Some((eid, prx));
                        entry_state = EntryState::PendingPlacement {
                            entry_id: eid,
                            enter_frame: payload.to_vec(),
                            buffered: VecDeque::new(),
                        };
                        continue;
                    }
                    (EntryState::PendingPlacement { .. }, FrameKind::Enter(_)) => {
                        continue;
                    }
                    (EntryState::PendingPlacement { buffered, .. }, FrameKind::Leave(_)) => {
                        cancel_and_join_placement(&mut placement_rx, &placement_slot).await;
                        buffered.clear();
                        entry_state = EntryState::Idle;
                        continue;
                    }
                    (EntryState::PendingPlacement { buffered, .. }, _) => {
                        if buffered.len() >= MAX_PENDING_ENTRY_FRAMES {
                            cancel_and_join_placement(&mut placement_rx, &placement_slot).await;
                            buffered.clear();
                            let until = Instant::now() + REFUSAL_QUIET_WINDOW;
                            {
                                let mut guard = demux_target.lock().unwrap_or_else(|e| e.into_inner());
                                guard.refused_until = Some(until);
                            }
                            entry_state = EntryState::Refused { until };
                        } else {
                            buffered.push_back(payload.to_vec());
                        }
                        continue;
                    }
                    (
                        EntryState::Placed {
                            placed_at,
                            last_activity,
                            input_seen,
                        },
                        FrameKind::Enter(_),
                    ) => {
                        if !*input_seen && placed_at.elapsed() < COALESCE_WINDOW {
                            *last_activity = Instant::now();
                            continue;
                        }
                        let needed = {
                            let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                            if ob.has_active_obligations {
                                Some(ob.trigger_recovery(&recovery_notify))
                            } else {
                                None
                            }
                        };
                        if let Some(epoch) = needed {
                            let deadline = Instant::now() + CALLER_RECOVERY_WAIT_BUDGET;
                            if wait_epoch_confirmed(&mut completed_epoch_rx, &obligations, epoch, deadline).await != WaitEpochOutcome::Confirmed {
                                in_conn.close(5u32.into(), b"recovery_unconfirmed");
                                break;
                            }
                        }
                        cancel_and_join_placement(&mut placement_rx, &placement_slot).await;
                        entry_seq += 1;
                        let eid = entry_seq;
                        let (ptx, prx) = oneshot::channel();
                        let cfg_clone = cfg.clone();
                        let ob_clone = obligations.clone();
                        let ph = tokio::spawn(async move {
                            let res = verify_and_place_output(&cfg_clone, &ob_clone).await;
                            let _ = ptx.send(res);
                        });
                        *placement_slot.lock().await = Some(ph);
                        placement_rx = Some((eid, prx));
                        entry_state = EntryState::PendingPlacement {
                            entry_id: eid,
                            enter_frame: payload.to_vec(),
                            buffered: VecDeque::new(),
                        };
                        continue;
                    }
                    (EntryState::Placed { .. }, FrameKind::Leave(_)) => {
                        let needed = {
                            let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                            if ob.has_active_obligations {
                                Some(ob.trigger_recovery(&recovery_notify))
                            } else {
                                None
                            }
                        };
                        if let Some(epoch) = needed {
                            let deadline = Instant::now() + CALLER_RECOVERY_WAIT_BUDGET;
                            if wait_epoch_confirmed(&mut completed_epoch_rx, &obligations, epoch, deadline).await != WaitEpochOutcome::Confirmed {
                                in_conn.close(5u32.into(), b"recovery_unconfirmed");
                                break;
                            }
                        } else if lan_socket.send_to(payload, lan_peer).await.is_err() {
                            break;
                        }
                        entry_state = EntryState::Idle;
                        continue;
                    }
                    (
                        EntryState::Placed {
                            last_activity,
                            input_seen,
                            ..
                        },
                        _,
                    ) => {
                        *last_activity = Instant::now();
                        *input_seen = true;
                    }
                    (EntryState::Idle, FrameKind::Leave(_)) => {
                        let _ = lan_socket.send_to(payload, lan_peer).await;
                        continue;
                    }
                    (EntryState::Idle, _) => {
                        continue;
                    }
                }
            }

            if wait_for_healthy_before_input(
                &obligations,
                &mut completed_epoch_rx,
                CALLER_RECOVERY_WAIT_BUDGET,
            )
            .await
            .is_err()
            {
                in_conn.close(5u32.into(), b"recovery_unconfirmed");
                break;
            }

            {
                let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                ob.record_obligation(kind);
            }
            if *cancel.borrow() {
                break;
            }
            if lan_socket.send_to(payload, lan_peer).await.is_err() {
                break;
            }
            if let FrameKind::PointerButton {
                button,
                pressed: false,
            } = kind
            {
                let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
                ob.clear_released_button(button);
            }
        }
    });

    (inbound_handle, outbound_handle)
}

async fn drain_session_for_decision(
    active_handles: &mut Option<SpliceHandles>,
    demux_target: &Arc<Mutex<DemuxTarget>>,
    obligations: &Arc<Mutex<BridgeObligations>>,
    recovery_notify: &Arc<Notify>,
    completed_epoch_rx: &mut watch::Receiver<u64>,
    decision_deadline: Instant,
) -> Result<(), (u32, &'static [u8])> {
    {
        let mut guard = demux_target.lock().unwrap_or_else(|e| e.into_inner());
        guard.active_gen = None;
        guard.tx = None;
        guard.cancel_tx = None;
        guard.refused_until = None;
    }

    if let Some(mut handles) = active_handles.take() {
        let _ = handles.cancel_tx.send(true);
        handles.conn.close(1u32.into(), b"superseded");

        let coop_deadline = std::cmp::min(decision_deadline, Instant::now() + COOPERATIVE_JOIN_BUDGET);
        let coop_res = tokio::time::timeout_at(
            coop_deadline,
            await_optional_triple(
                &mut handles.inbound,
                &mut handles.outbound,
                &mut handles.clipboard,
            ),
        )
        .await;

        if coop_res.is_err() {
            if let Some(h) = &handles.inbound {
                h.abort();
            }
            if let Some(h) = &handles.outbound {
                h.abort();
            }
            if let Some(h) = &handles.clipboard {
                h.abort();
            }
            let abort_deadline = std::cmp::min(decision_deadline, Instant::now() + ABORT_DRAIN_BUDGET);
            let abort_res = tokio::time::timeout_at(
                abort_deadline,
                await_optional_triple(
                    &mut handles.inbound,
                    &mut handles.outbound,
                    &mut handles.clipboard,
                ),
            )
            .await;
            if abort_res.is_err() {
                *active_handles = Some(handles);
                return Err((3, b"busy_draining"));
            }
        }

        let placement_timed_out = {
            let mut guard = handles.placement_slot.lock().await;
            if let Some(ph) = guard.as_mut() {
                ph.abort();
                if tokio::time::timeout_at(decision_deadline, &mut *ph)
                    .await
                    .is_err()
                {
                    true
                } else {
                    *guard = None;
                    false
                }
            } else {
                false
            }
        };
        if placement_timed_out {
            *active_handles = Some(handles);
            return Err((3, b"busy_draining"));
        }
    }

    loop {
        let reaper_clear = {
            let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
            ob.sweep_reaper()
        };
        if reaper_clear {
            break;
        }
        if Instant::now() >= decision_deadline {
            return Err((3, b"busy_reaping"));
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let needed = {
        let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
        match ob.recovery_gate {
            RecoveryGate::Healthy if !ob.has_active_obligations => None,
            RecoveryGate::ExhaustedFailClosed => return Err((5, b"recovery_unconfirmed")),
            _ => Some(ob.trigger_recovery(recovery_notify)),
        }
    };

    if let Some(epoch) = needed {
        if wait_epoch_confirmed(completed_epoch_rx, obligations, epoch, decision_deadline).await
            != WaitEpochOutcome::Confirmed
        {
            return Err((5, b"recovery_unconfirmed"));
        }
    }

    Ok(())
}

async fn await_active_session(handles: &mut SpliceHandles) {
    if handles.inbound.is_some() || handles.outbound.is_some() {
        tokio::select! {
            res = async {
                if let Some(h) = handles.inbound.as_mut() {
                    h.await
                } else {
                    std::future::pending().await
                }
            }, if handles.inbound.is_some() => {
                let _ = res;
                handles.inbound = None;
            }
            res = async {
                if let Some(h) = handles.outbound.as_mut() {
                    h.await
                } else {
                    std::future::pending().await
                }
            }, if handles.outbound.is_some() => {
                let _ = res;
                handles.outbound = None;
            }
        }
    } else {
        let mut guard = handles.placement_slot.lock().await;
        if let Some(ph) = guard.as_mut() {
            ph.abort();
            let _ = (&mut *ph).await;
            *guard = None;
        } else {
            drop(guard);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

async fn serve(args: Args) -> Result<(), Box<dyn Error + Send + Sync>> {
    let (shutdown_tx, shutdown_rx) = oneshot::channel();
    tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        let _ = shutdown_tx.send(());
    });
    serve_with_shutdown(args, shutdown_rx).await
}

async fn serve_with_shutdown(
    args: Args,
    shutdown_rx: oneshot::Receiver<()>,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let std_lan = bind(&args.lan_local)?;
    let lan_socket = Arc::new(tokio::net::UdpSocket::from_std(std_lan)?);
    let obligations = Arc::new(Mutex::new(BridgeObligations::new_startup_recovery()));
    let recovery_notify = Arc::new(Notify::new());
    let active_slot = Arc::new(Mutex::new(ActiveRecoverySlot::default()));
    let (completed_epoch_tx, mut completed_epoch_rx) = watch::channel(0u64);
    let (bg_shutdown_tx, bg_shutdown_rx) = watch::channel(false);

    let demux_target = Arc::new(Mutex::new(DemuxTarget {
        active_gen: None,
        refused_until: None,
        tx: None,
        cancel_tx: None,
    }));

    let driver = RecoveryDriver {
        floor_file: args.serial_floor_file.clone(),
        seat_file: args.seat_state_file.clone(),
        lan_socket: lan_socket.clone(),
        lan_peer: args.lan_peer,
        obligations: obligations.clone(),
        recovery_notify: recovery_notify.clone(),
        active_slot: active_slot.clone(),
        completed_epoch_tx,
        in_memory_floor: None,
    };
    let mut driver_handle = tokio::spawn(driver.run(bg_shutdown_rx.clone()));
    let mut demux_handle = tokio::spawn(run_local_udp_demux(
        lan_socket.clone(),
        args.lan_peer,
        active_slot.clone(),
        demux_target.clone(),
        bg_shutdown_rx.clone(),
    ));
    let (clip_hub, mut clip_handle) = if args.clipboard {
        let (hub, h) = ClipboardHub::spawn(bg_shutdown_rx);
        (Some(hub), Some(h))
    } else {
        (None, None)
    };
    let niri_cfg = match (
        args.role,
        &args.niri_bin,
        &args.busctl_bin,
        &args.enter_output,
    ) {
        (Role::Listen, Some(niri_bin), Some(busctl_bin), Some(enter_output)) => {
            let sock = args
                .niri_socket
                .clone()
                .or_else(|| std::env::var_os("NIRI_SOCKET").map(PathBuf::from))
                .ok_or("NIRI_SOCKET missing for listen role")?;
            Some(NiriSessionConfig {
                niri_bin: niri_bin.clone(),
                busctl_bin: busctl_bin.clone(),
                niri_socket: sock,
                enter_output: enter_output.clone(),
                #[cfg(test)]
                test_placement_hold: args.test_placement_hold.clone(),
            })
        }
        _ => None,
    };

    let endpoint = match args.role {
        Role::Listen => {
            let quic_socket = bind(&args.quic_addr)?;
            Endpoint::new(
                EndpointConfig::default(),
                Some(server_config(&args.cert, &args.key)?),
                quic_socket,
                Arc::new(TokioRuntime),
            )?
        }
        Role::Dial => {
            let mut ep = Endpoint::client(SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0)))?;
            ep.set_default_client_config(client_config(&args.cert, &args.key)?);
            ep
        }
    };

    let latest_slot = Arc::new(Mutex::new(LatestConnSlot {
        closed: false,
        pending: None,
    }));
    let conn_notify = Arc::new(Notify::new());

    let mut accept_handle = if args.role == Role::Listen {
        let ep = endpoint.clone();
        let slot = latest_slot.clone();
        let notify = conn_notify.clone();
        Some(tokio::spawn(async move {
            let sem = Arc::new(Semaphore::new(MAX_CONCURRENT_HANDSHAKES));
            let mut handshakes = JoinSet::new();
            while let Some(incoming) = ep.accept().await {
                if let Ok(permit) = sem.clone().try_acquire_owned() {
                    let s = slot.clone();
                    let n = notify.clone();
                    handshakes.spawn(async move {
                        let _permit = permit;
                        if let Ok(Ok(conn)) =
                            tokio::time::timeout(HANDSHAKE_TIMEOUT, incoming).await
                        {
                            s.lock().unwrap_or_else(|e| e.into_inner()).publish(conn);
                            n.notify_one();
                        }
                    });
                } else {
                    incoming.refuse();
                }
                while handshakes.try_join_next().is_some() {}
            }
            handshakes.abort_all();
            while handshakes.join_next().await.is_some() {}
        }))
    } else {
        None
    };

    let mut active_handles: Option<SpliceHandles> = None;
    let mut session_gen: u64 = 0;

    tokio::pin!(shutdown_rx);

    loop {
        let next_conn = { latest_slot.lock().unwrap_or_else(|e| e.into_inner()).take() };
        if let Some(new_conn) = next_conn {
            let decision_deadline = Instant::now() + REPLACEMENT_DECISION_BUDGET;
            match drain_session_for_decision(
                &mut active_handles,
                &demux_target,
                &obligations,
                &recovery_notify,
                &mut completed_epoch_rx,
                decision_deadline,
            )
            .await
            {
                Ok(()) => {
                    session_gen += 1;
                    let (tx, rx) = mpsc::channel(LOCAL_TO_QUIC_CAP);
                    let (cancel_tx, cancel_rx) = watch::channel(false);
                    {
                        let mut guard = demux_target.lock().unwrap_or_else(|e| e.into_inner());
                        guard.active_gen = Some(SessionForwardTarget { session_gen });
                        guard.tx = Some(tx);
                        guard.cancel_tx = Some(cancel_tx.clone());
                    }
                    let placement_slot = Arc::new(tokio::sync::Mutex::new(None));
                    let (in_h, out_h) = spawn_splice_tasks(
                        new_conn.clone(),
                        lan_socket.clone(),
                        args.lan_peer,
                        niri_cfg.clone(),
                        obligations.clone(),
                        recovery_notify.clone(),
                        completed_epoch_rx.clone(),
                        rx,
                        demux_target.clone(),
                        cancel_rx.clone(),
                        placement_slot.clone(),
                    );
                    let clip_h = clip_hub
                        .as_ref()
                        .map(|hub| spawn_clipboard_session(new_conn.clone(), hub.clone(), cancel_rx));
                    active_handles = Some(SpliceHandles {
                        inbound: Some(in_h),
                        outbound: Some(out_h),
                        clipboard: clip_h,
                        placement_slot,
                        conn: new_conn,
                        cancel_tx,
                    });
                }
                Err((code, reason)) => {
                    new_conn.close(code.into(), reason);
                }
            }
            continue;
        }

        if args.role == Role::Dial && active_handles.is_none() {
            let dial_res = tokio::select! {
                biased;
                _ = &mut shutdown_rx => break,
                res = async {
                    match endpoint.connect(args.quic_addr, "cursor-bridge") {
                        Ok(connecting) => match tokio::time::timeout(CONNECT_TIMEOUT, connecting).await {
                            Ok(Ok(conn)) => Some(conn),
                            _ => None,
                        },
                        Err(_) => None,
                    }
                } => res,
            };
            match dial_res {
                Some(conn) => {
                    latest_slot
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .publish(conn);
                    continue;
                }
                _ => {
                    tokio::select! {
                        biased;
                        _ = &mut shutdown_rx => break,
                        _ = tokio::time::sleep(Duration::from_secs(1)) => continue,
                    }
                }
            }
        }

        tokio::select! {
            biased;
            _ = &mut shutdown_rx => break,
            _ = conn_notify.notified() => continue,
            _ = async {
                if let Some(handles) = &mut active_handles {
                    await_active_session(handles).await;
                } else {
                    std::future::pending::<()>().await;
                }
            } => {
                let decision_deadline = Instant::now() + REPLACEMENT_DECISION_BUDGET;
                let _ = drain_session_for_decision(
                    &mut active_handles,
                    &demux_target,
                    &obligations,
                    &recovery_notify,
                    &mut completed_epoch_rx,
                    decision_deadline,
                )
                .await;
            }
        }
    }

    // Bounded shutdown sequence (SHUTDOWN_DECISION_BUDGET = 500ms + 50ms bg stop).
    let shutdown_deadline = Instant::now() + SHUTDOWN_DECISION_BUDGET;
    latest_slot
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .seal_and_close();
    if let Some(ah) = accept_handle.take() {
        ah.abort();
        let _ = tokio::time::timeout_at(shutdown_deadline, ah).await;
    }
    let drain_res = drain_session_for_decision(
        &mut active_handles,
        &demux_target,
        &obligations,
        &recovery_notify,
        &mut completed_epoch_rx,
        shutdown_deadline,
    )
    .await;

    let _ = bg_shutdown_tx.send(true);
    active_slot
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
    let bg_deadline = Instant::now() + BG_STOP_BUDGET;
    let bg_res = tokio::time::timeout_at(bg_deadline, async {
        let _ = (&mut driver_handle).await;
        let _ = (&mut demux_handle).await;
        if let Some(h) = &mut clip_handle {
            let _ = h.await;
        }
    })
    .await;
    if bg_res.is_err() {
        driver_handle.abort();
        demux_handle.abort();
        if let Some(h) = &clip_handle {
            h.abort();
        }
    }
    endpoint.close(0u32.into(), b"shutdown");

    let clean = drain_res.is_ok() && bg_res.is_ok() && {
        let mut ob = obligations.lock().unwrap_or_else(|e| e.into_inner());
        ob.sweep_reaper()
            && ob.recovery_gate == RecoveryGate::Healthy
            && !ob.has_active_obligations
    };
    if !clean {
        return Err("uncleaned shutdown".into());
    }
    Ok(())
}

fn server_config(cert: &Path, key: &Path) -> Result<ServerConfig, Box<dyn Error + Send + Sync>> {
    let certificate = read_cert(cert)?;
    let key = PrivateKeyDer::Pkcs8(read_key(key)?);
    let verifier = Arc::new(Verifier(certificate.clone()));
    let rustls_config = rustls::ServerConfig::builder()
        .with_client_cert_verifier(verifier)
        .with_single_cert(vec![certificate], key)?;
    let mut config = ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(rustls_config)?,
    ));
    config.max_incoming(16);
    config.incoming_buffer_size(64 * 1024);
    config.incoming_buffer_size_total(512 * 1024);
    config.transport_config(transport());
    Ok(config)
}

fn client_config(cert: &Path, key: &Path) -> Result<ClientConfig, Box<dyn Error + Send + Sync>> {
    let certificate = read_cert(cert)?;
    let key = PrivateKeyDer::Pkcs8(read_key(key)?);
    let verifier = Arc::new(Verifier(certificate.clone()));
    let rustls_config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_client_auth_cert(vec![certificate], key)?;
    let mut config = ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(rustls_config)?,
    ));
    config.transport_config(transport());
    Ok(config)
}

fn transport() -> Arc<TransportConfig> {
    let mut transport = TransportConfig::default();
    transport.max_concurrent_uni_streams(VarInt::from_u32(32));
    transport.max_concurrent_bidi_streams(VarInt::from_u32(16));
    transport.stream_receive_window(VarInt::from_u32(256 * 1024));
    transport.receive_window(VarInt::from_u32(2 * 1024 * 1024));
    transport.max_idle_timeout(Some(IdleTimeout::try_from(Duration::from_secs(20)).unwrap()));
    Arc::new(transport)
}

#[derive(Debug)]
struct Verifier(CertificateDer<'static>);

impl rustls::client::danger::ServerCertVerifier for Verifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        if end_entity == &self.0 {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General(
                "unexpected cursor-bridge server certificate".into(),
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::PeerIncompatible(
            rustls::PeerIncompatible::Tls12NotOffered,
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

impl rustls::server::danger::ClientCertVerifier for Verifier {
    fn offer_client_auth(&self) -> bool {
        true
    }

    fn client_auth_mandatory(&self) -> bool {
        true
    }

    fn root_hint_subjects(&self) -> &[rustls::DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::server::danger::ClientCertVerified, rustls::Error> {
        if end_entity == &self.0 {
            Ok(rustls::server::danger::ClientCertVerified::assertion())
        } else {
            Err(rustls::Error::General(
                "unexpected cursor-bridge client certificate".into(),
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::PeerIncompatible(
            rustls::PeerIncompatible::Tls12NotOffered,
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn read_cert(path: &Path) -> Result<CertificateDer<'static>, Box<dyn Error + Send + Sync>> {
    let mut reader = std::io::BufReader::new(File::open(path)?);
    rustls_pemfile::certs(&mut reader)
        .next()
        .ok_or("certificate file is empty")?
        .map_err(Into::into)
}

fn read_key(path: &Path) -> Result<PrivatePkcs8KeyDer<'static>, Box<dyn Error + Send + Sync>> {
    let mut reader = std::io::BufReader::new(File::open(path)?);
    match rustls_pemfile::private_key(&mut reader)?.ok_or("key file is empty")? {
        PrivateKeyDer::Pkcs8(key) => Ok(key),
        _ => Err("cursor-bridge key must be PKCS#8".into()),
    }
}

fn bind(address: &SocketAddr) -> Result<UdpSocket, Box<dyn Error + Send + Sync>> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, None)?;
    socket.bind(&SockAddr::from(*address))?;
    socket.set_nonblocking(true)?;
    Ok(socket.into())
}

fn require_ipv4_loopback(addr: SocketAddr, flag: &str) -> Result<SocketAddr, Box<dyn Error + Send + Sync>> {
    if addr.is_ipv4() && addr.ip().is_loopback() {
        Ok(addr)
    } else {
        Err(format!("{flag} must be an IPv4 loopback address").into())
    }
}

fn parse(mut args: impl Iterator<Item = String>) -> Result<Args, Box<dyn Error + Send + Sync>> {
    let mut role = None;
    let mut quic_addr = None;
    let mut lan_local = None;
    let mut lan_peer = None;
    let mut cert = None;
    let mut key = None;
    let mut niri_bin = None;
    let mut busctl_bin = None;
    let mut enter_output = None;
    let mut niri_socket = None;
    let mut serial_floor_file = None;
    let mut seat_state_file = None;
    let mut clipboard = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--listen" => role = Some(Role::Listen),
            "--dial" => role = Some(Role::Dial),
            "--quic-addr" => quic_addr = Some(take(&mut args, "--quic-addr")?.parse()?),
            "--lan-local" => {
                let addr: SocketAddr = take(&mut args, "--lan-local")?.parse()?;
                lan_local = Some(require_ipv4_loopback(addr, "--lan-local")?);
            }
            "--lan-peer" => {
                let addr: SocketAddr = take(&mut args, "--lan-peer")?.parse()?;
                lan_peer = Some(require_ipv4_loopback(addr, "--lan-peer")?);
            }
            "--cert" => cert = Some(PathBuf::from(take(&mut args, "--cert")?)),
            "--key" => key = Some(PathBuf::from(take(&mut args, "--key")?)),
            "--niri-bin" => niri_bin = Some(PathBuf::from(take(&mut args, "--niri-bin")?)),
            "--busctl-bin" => busctl_bin = Some(PathBuf::from(take(&mut args, "--busctl-bin")?)),
            "--enter-output" => enter_output = Some(take(&mut args, "--enter-output")?),
            "--niri-socket" => niri_socket = Some(PathBuf::from(take(&mut args, "--niri-socket")?)),
            "--serial-floor-file" => {
                serial_floor_file = Some(PathBuf::from(take(&mut args, "--serial-floor-file")?))
            }
            "--seat-state-file" => {
                seat_state_file = Some(PathBuf::from(take(&mut args, "--seat-state-file")?))
            }
            "--clipboard" => clipboard = true,
            other => return Err(format!("unknown argument {other}").into()),
        }
    }

    Ok(Args {
        role: role.ok_or("missing --listen or --dial")?,
        quic_addr: quic_addr.ok_or("missing --quic-addr")?,
        lan_local: lan_local.ok_or("missing --lan-local")?,
        lan_peer: lan_peer.ok_or("missing --lan-peer")?,
        cert: cert.ok_or("missing --cert")?,
        key: key.ok_or("missing --key")?,
        niri_bin: {
            let role_val = role.unwrap();
            let has_any = niri_bin.is_some()
                || busctl_bin.is_some()
                || enter_output.is_some()
                || niri_socket.is_some();
            if role_val == Role::Dial && has_any {
                return Err("readiness options are only valid with --listen".into());
            }
            if role_val == Role::Listen && has_any {
                if niri_bin.is_none() || busctl_bin.is_none() || enter_output.is_none() {
                    return Err(
                        "partial readiness options: --niri-bin, --busctl-bin, and --enter-output must all be provided together"
                            .into(),
                    );
                }
            }
            niri_bin
        },
        busctl_bin,
        enter_output,
        niri_socket,
        serial_floor_file: serial_floor_file.ok_or("missing --serial-floor-file")?,
        seat_state_file: seat_state_file.ok_or("missing --seat-state-file")?,
        clipboard,
        #[cfg(test)]
        test_placement_hold: None,
    })
}

fn take(
    args: &mut impl Iterator<Item = String>,
    flag: &str,
) -> Result<String, Box<dyn Error + Send + Sync>> {
    args.next().ok_or(format!("missing value for {flag}").into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rcgen::CertificateParams;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_dir(prefix: &str) -> PathBuf {
        let seq = TEMP_SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("{prefix}-{}-{seq}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn temp_cert_files() -> (PathBuf, PathBuf, PathBuf) {
        let key = rcgen::KeyPair::generate().unwrap();
        let certificate = CertificateParams::new(vec!["cursor-bridge".to_string()])
            .unwrap()
            .self_signed(&key)
            .unwrap();
        let dir = temp_dir("cursor-bridge-cert");
        let cert_path = dir.join("cert.pem");
        let key_path = dir.join("key.pem");
        std::fs::write(&cert_path, certificate.pem()).unwrap();
        std::fs::write(&key_path, key.serialize_pem()).unwrap();
        (dir, cert_path, key_path)
    }

    fn memory_socket() -> (UdpSocket, SocketAddr) {
        let socket = bind(&SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        let address = socket.local_addr().unwrap();
        (socket, address)
    }

    fn blocking_socket() -> (UdpSocket, SocketAddr) {
        let socket = UdpSocket::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let address = socket.local_addr().unwrap();
        (socket, address)
    }

    fn json_output(name: &str, logical: Option<(i32, i32, u32, u32, f64, &str)>, current_mode: Option<usize>) -> String {
        let log_json = match logical {
            Some((x, y, w, h, s, t)) => format!(
                r#"{{"x":{x},"y":{y},"width":{w},"height":{h},"scale":{s:?},"transform":"{t}"}}"#
            ),
            None => "null".to_string(),
        };
        let cm_json = match current_mode {
            Some(i) => i.to_string(),
            None => "null".to_string(),
        };
        format!(
            r#"{{"name":"{name}","make":"LG","model":"27","serial":null,"physical_size":[600,340],"modes":[{{"width":1440,"height":2560,"refresh_rate":60000,"is_preferred":true}}],"current_mode":{cm_json},"is_custom_mode":false,"vrr_supported":false,"vrr_enabled":false,"logical":{log_json}}}"#
        )
    }

    fn json_ws(
        id: u64,
        idx: u8,
        output: Option<&str>,
        is_active: bool,
        is_focused: bool,
        active_window_id: Option<u64>,
    ) -> String {
        let out_json = match output {
            Some(o) => format!(r#""{o}""#),
            None => "null".to_string(),
        };
        let aw_json = match active_window_id {
            Some(w) => w.to_string(),
            None => "null".to_string(),
        };
        format!(
            r#"{{"id":{id},"idx":{idx},"name":null,"output":{out_json},"is_urgent":false,"is_active":{is_active},"is_focused":{is_focused},"active_window_id":{aw_json}}}"#
        )
    }

    fn json_win(id: u64, title: Option<&str>, workspace_id: Option<u64>, is_focused: bool) -> String {
        let title_json = match title {
            Some(t) => format!(r#""{t}""#),
            None => "null".to_string(),
        };
        let ws_json = match workspace_id {
            Some(w) => w.to_string(),
            None => "null".to_string(),
        };
        format!(
            r#"{{"id":{id},"title":{title_json},"app_id":"term","pid":1234,"workspace_id":{ws_json},"is_focused":{is_focused},"is_floating":false,"is_urgent":false,"layout":{{"pos_in_scrolling_layout":[1,1],"tile_size":[100.0,100.0],"window_size":[100,100],"tile_pos_in_workspace_view":[0.0,0.0],"window_offset_in_tile":[0.0,0.0]}},"focus_timestamp":null}}"#
        )
    }

    fn json_layer(ns: &str, output: &str, layer: &str, interactivity: &str) -> String {
        format!(
            r#"{{"namespace":"{ns}","output":"{output}","layer":"{layer}","keyboard_interactivity":"{interactivity}"}}"#
        )
    }

    #[test]
    fn leave_event_matches_lan_mouse() {
        let leave = encode_control_frame(PROTO_LEAVE, 0);
        assert_eq!(leave, [9, 0, 0, 0, 0]);
        assert!(matches!(validate_d5_frame(&leave), Ok(FrameKind::Leave(0))));
    }

    #[test]
    fn certificate_round_trips() {
        let (dir, cert_path, key_path) = temp_cert_files();
        assert!(read_cert(&cert_path).is_ok());
        assert!(read_key(&key_path).is_ok());
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn parses_listen_and_dial_args_and_rejects_non_loopback() {
        let listen = parse(
            [
                "--listen",
                "--quic-addr",
                "0.0.0.0:4243",
                "--lan-local",
                "127.0.0.1:4244",
                "--lan-peer",
                "127.0.0.1:4242",
                "--cert",
                "/tmp/cert",
                "--key",
                "/tmp/key",
                "--serial-floor-file",
                "/tmp/floor",
                "--seat-state-file",
                "/tmp/seat",
            ]
            .into_iter()
            .map(String::from),
        )
        .unwrap();
        assert_eq!(listen.role, Role::Listen);

        let bad = parse(
            [
                "--dial",
                "--quic-addr",
                "192.168.10.75:4243",
                "--lan-local",
                "0.0.0.0:4244",
                "--lan-peer",
                "127.0.0.1:4242",
                "--cert",
                "/tmp/cert",
                "--key",
                "/tmp/key",
                "--serial-floor-file",
                "/tmp/floor",
                "--seat-state-file",
                "/tmp/seat",
            ]
            .into_iter()
            .map(String::from),
        );
        assert!(bad.is_err());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn server_rejects_unauthenticated_and_wrong_cert_clients() {
        let (dir_server, server_cert, server_key) = temp_cert_files();
        let (dir_rogue, rogue_cert, rogue_key) = temp_cert_files();

        let server = server_config(&server_cert, &server_key).unwrap();
        let (listener, listen_addr) = memory_socket();
        let endpoint = Endpoint::new(
            EndpointConfig::default(),
            Some(server),
            listener,
            Arc::new(TokioRuntime),
        )
        .unwrap();

        let (accepted_tx, mut accepted_rx) = mpsc::unbounded_channel();
        let accept_loop = tokio::spawn(async move {
            while let Some(incoming) = endpoint.accept().await {
                let tx = accepted_tx.clone();
                tokio::spawn(async move {
                    if let Ok(conn) = incoming.await {
                        let _ = tx.send(conn);
                    }
                });
            }
        });

        async fn assert_rejected(connecting: quinn::Connecting, label: &str) {
            match tokio::time::timeout(Duration::from_secs(2), connecting).await {
                Ok(Err(_)) => {}
                Ok(Ok(conn)) => {
                    let closed = tokio::time::timeout(Duration::from_secs(2), conn.closed())
                        .await
                        .unwrap_or_else(|_| panic!("{label}: stayed open"));
                    assert!(
                        !matches!(closed, quinn::ConnectionError::LocallyClosed),
                        "{label}: expected peer rejection, got {closed:?}"
                    );
                }
                Err(_) => panic!("{label}: timed out"),
            }
        }

        let mut no_auth_client =
            Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        let pinned_server_verifier = Arc::new(Verifier(read_cert(&server_cert).unwrap()));
        let no_auth_rustls = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(pinned_server_verifier)
            .with_no_client_auth();
        let mut no_auth_quinn = ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(no_auth_rustls).unwrap(),
        ));
        no_auth_quinn.transport_config(transport());
        no_auth_client.set_default_client_config(no_auth_quinn);
        assert_rejected(
            no_auth_client.connect(listen_addr, "cursor-bridge").unwrap(),
            "no-auth client",
        )
        .await;

        // 2. Client pinning legitimate server cert but presenting rogue client cert must be rejected by server.
        let mut wrong_client =
            Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        let server_verifier = Arc::new(Verifier(read_cert(&server_cert).unwrap()));
        let wrong_client_rustls = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(server_verifier)
            .with_client_auth_cert(
                vec![read_cert(&rogue_cert).unwrap()],
                PrivateKeyDer::Pkcs8(read_key(&rogue_key).unwrap()),
            )
            .unwrap();
        let mut wrong_client_quinn = ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(wrong_client_rustls).unwrap(),
        ));
        wrong_client_quinn.transport_config(transport());
        wrong_client.set_default_client_config(wrong_client_quinn);
        assert_rejected(
            wrong_client.connect(listen_addr, "cursor-bridge").unwrap(),
            "wrong-client-cert",
        )
        .await;

        // 3. Client rejecting rogue server cert.
        let mut strict_client =
            Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        strict_client.set_default_client_config(client_config(&rogue_cert, &rogue_key).unwrap());
        assert_rejected(
            strict_client.connect(listen_addr, "cursor-bridge").unwrap(),
            "rogue-server-cert",
        )
        .await;

        assert!(accepted_rx.try_recv().is_err());
        accept_loop.abort();
        std::fs::remove_dir_all(dir_server).ok();
        std::fs::remove_dir_all(dir_rogue).ok();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn v8_1_establishment_precedes_nonzero_issuance_preventing_serial_reuse_across_paused_native_and_floor_loss() {
        let dir = temp_dir("cursor-bridge-v8-1");
        let floor_file = dir.join("bridge-serial");
        let seat_file = dir.join("native-seat");

        // 1. Paused-native pre-establishment trace:
        // Native writes (CLEAN, serial_established=0), then pauses.
        atomic_write_file(
            &seat_file,
            "lifetime_id=comp-1\nstate=CLEAN\nserial_established=0\n",
        )
        .unwrap();

        let (lan_std, lan_addr) = memory_socket();
        let lan_sock = Arc::new(tokio::net::UdpSocket::from_std(lan_std).unwrap());
        let (native_sock, native_addr) = blocking_socket();

        let obligations = Arc::new(Mutex::new(BridgeObligations::new_startup_recovery()));
        let recovery_notify = Arc::new(Notify::new());
        let active_slot = Arc::new(Mutex::new(ActiveRecoverySlot::default()));
        let (completed_tx, _completed_rx) = watch::channel(0u64);

        let mut driver = RecoveryDriver {
            floor_file: floor_file.clone(),
            seat_file: seat_file.clone(),
            lan_socket: lan_sock.clone(),
            lan_peer: native_addr,
            obligations: obligations.clone(),
            recovery_notify: recovery_notify.clone(),
            active_slot: active_slot.clone(),
            completed_epoch_tx: completed_tx.clone(),
            in_memory_floor: None,
        };

        // Run step_once while native is paused (no serial_established=1 commit):
        let step = driver.step_once().await;
        assert_eq!(step, DriverStep::Retry);
        assert_eq!(read_floor_file(&floor_file), Ok(Some(0)));

        // Native only receives Ping [6], ZERO Leave(serial >= 1)!
        let mut buf = [0u8; 32];
        let (n, from) = native_sock.recv_from(&mut buf).unwrap();
        assert_eq!(from, lan_addr);
        assert_eq!(&buf[..n], &[PROTO_PING]);
        assert!(native_sock
            .set_read_timeout(Some(Duration::from_millis(50)))
            .is_ok());
        assert!(native_sock.recv_from(&mut buf).is_err());

        // Delete bridge-serial and restart driver: zero nonzero serials were issued.
        std::fs::remove_file(&floor_file).unwrap();
        let mut driver2 = RecoveryDriver {
            floor_file: floor_file.clone(),
            seat_file: seat_file.clone(),
            lan_socket: lan_sock.clone(),
            lan_peer: native_addr,
            obligations: Arc::new(Mutex::new(BridgeObligations::new_startup_recovery())),
            recovery_notify: Arc::new(Notify::new()),
            active_slot: Arc::new(Mutex::new(ActiveRecoverySlot::default())),
            completed_epoch_tx: watch::channel(0u64).0,
            in_memory_floor: None,
        };
        assert_eq!(driver2.step_once().await, DriverStep::Retry);
        assert_eq!(read_floor_file(&floor_file), Ok(Some(0)));

        // Now native unpauses and commits serial_established=1, then responds with Ack(1).
        atomic_write_file(
            &seat_file,
            "lifetime_id=comp-1\nstate=CLEAN\nserial_established=1\n",
        )
        .unwrap();
        let slot_clone = driver2.active_slot.clone();
        let native_responder = tokio::spawn(async move {
            let mut b = [0u8; 32];
            loop {
                if let Ok((n, _)) = native_sock.recv_from(&mut b) {
                    if n == 5 && b[0] == PROTO_LEAVE {
                        let serial = u32::from_be_bytes(b[1..5].try_into().unwrap());
                        slot_clone
                            .lock()
                            .unwrap()
                            .deliver_ack(serial);
                        break serial;
                    }
                }
            }
        });
        assert_eq!(driver2.step_once().await, DriverStep::Confirmed);
        let issued_serial = native_responder.await.unwrap();
        assert_eq!(issued_serial, 1);
        assert_eq!(read_floor_file(&floor_file), Ok(Some(1)));

        // 2. Paused-native post-establishment trace (Astra's counterexample):
        // Delete bridge-serial while native-seat has serial_established=1 -> immediate ExhaustedFailClosed!
        std::fs::remove_file(&floor_file).unwrap();
        let mut driver3 = RecoveryDriver {
            floor_file: floor_file.clone(),
            seat_file: seat_file.clone(),
            lan_socket: lan_sock.clone(),
            lan_peer: native_addr,
            obligations: Arc::new(Mutex::new(BridgeObligations::new_startup_recovery())),
            recovery_notify: Arc::new(Notify::new()),
            active_slot: Arc::new(Mutex::new(ActiveRecoverySlot::default())),
            completed_epoch_tx: watch::channel(0u64).0,
            in_memory_floor: None,
        };
        assert_eq!(driver3.step_once().await, DriverStep::Exhausted);
        assert_eq!(
            driver3.obligations.lock().unwrap().recovery_gate,
            RecoveryGate::ExhaustedFailClosed
        );

        // 3. Corruption refusal: floor >= 1 while serial_established == 0 -> ExhaustedFailClosed.
        atomic_write_file(&floor_file, "floor=1\n").unwrap();
        atomic_write_file(
            &seat_file,
            "lifetime_id=comp-1\nstate=CLEAN\nserial_established=0\n",
        )
        .unwrap();
        let mut driver4 = RecoveryDriver {
            floor_file: floor_file.clone(),
            seat_file: seat_file.clone(),
            lan_socket: lan_sock,
            lan_peer: native_addr,
            obligations: Arc::new(Mutex::new(BridgeObligations::new_startup_recovery())),
            recovery_notify: Arc::new(Notify::new()),
            active_slot: Arc::new(Mutex::new(ActiveRecoverySlot::default())),
            completed_epoch_tx: watch::channel(0u64).0,
            in_memory_floor: None,
        };
        assert_eq!(driver4.step_once().await, DriverStep::Exhausted);

        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn v7_1_and_retained_v6_to_d_behavioral_suite() {
        // 1. D5 exact validation + bounds:
        assert!(validate_d5_frame(&[PROTO_PING]).is_ok());
        assert!(validate_d5_frame(&[PROTO_LEAVE, 0, 0, 0, 1]).is_ok());
        assert!(validate_d5_frame(&[PROTO_LEAVE, 0, 0, 0]).is_err());
        assert!(validate_d5_frame(&[1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2]).is_err()); // button state > 1
        assert!(validate_d5_frame(&[11, 0]).is_err());

        // 2. LocalUdpDemux spoofed sender drop & Ack(serial != 0) exclusive routing (P1-3, V3-5):
        let (lan_std, lan_addr) = memory_socket();
        let lan_sock = Arc::new(tokio::net::UdpSocket::from_std(lan_std).unwrap());
        let (good_peer, good_peer_addr) = blocking_socket();
        let (spoof_peer, _) = blocking_socket();
        let active_slot = Arc::new(Mutex::new(ActiveRecoverySlot::default()));
        let (tx, mut rx) = mpsc::channel(LOCAL_TO_QUIC_CAP);
        let (cancel_tx, _cancel_rx) = watch::channel(false);
        let demux_target = Arc::new(Mutex::new(DemuxTarget {
            active_gen: Some(SessionForwardTarget { session_gen: 1 }),
            refused_until: None,
            tx: Some(tx),
            cancel_tx: Some(cancel_tx),
        }));
        let (sd_tx, sd_rx) = watch::channel(false);
        let demux = tokio::spawn(run_local_udp_demux(
            lan_sock,
            good_peer_addr,
            active_slot.clone(),
            demux_target,
            sd_rx,
        ));

        // Spoofed sender is dropped.
        spoof_peer.send_to(&[PROTO_PING], lan_addr).unwrap();
        // Ack(7) routes exclusively to ActiveRecoverySlot, NOT to QUIC rx.
        let (ack_tx, ack_rx) = oneshot::channel();
        active_slot
            .lock()
            .unwrap()
            .install(1, NonZeroU32::new(7).unwrap(), ack_tx);
        good_peer
            .send_to(&encode_control_frame(PROTO_ACK, 7), lan_addr)
            .unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(500), ack_rx)
            .await
            .is_ok());
        assert!(rx.try_recv().is_err());

        // Ordinary Enter(0) from good_peer forwards to QUIC rx.
        good_peer
            .send_to(&encode_control_frame(PROTO_ENTER, 0), lan_addr)
            .unwrap();
        let forwarded = tokio::time::timeout(Duration::from_millis(500), rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(forwarded, encode_control_frame(PROTO_ENTER, 0));
        let _ = sd_tx.send(true);
        let _ = demux.await;

        // 3. R2 >64 KiB stdout drain refusal & SpawnedChildGuard slot accounting:
        let obligations = Arc::new(Mutex::new(BridgeObligations::new_startup_recovery()));
        let res = run_bounded_command(
            Path::new("/bin/sh"),
            &["-c", "dd if=/dev/zero bs=1024 count=80 2>/dev/null"],
            &[],
            &obligations,
            Instant::now() + Duration::from_millis(250),
        )
        .await;
        assert!(res.is_err());
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(obligations.lock().unwrap().sweep_reaper());

        // 4. R1 busctl (uo) & focused-output / layers / focused-window parsers:
        assert_eq!(
            parse_busctl_object_path("o \"/org/freedesktop/login1/session/_32\""),
            Some("/org/freedesktop/login1/session/_32".to_string())
        );
        assert_eq!(parse_busctl_user_uid("(uo) 1000 \"/org/freedesktop/login1/user/_1000\""), Some(1000));
        assert!(parse_focused_output_json(
            &json_output("DP-2", Some((0, 0, 1440, 2560, 1.0, "Normal")), Some(0)),
            "DP-2"
        ));
        assert!(!parse_layers_allows_entry_json(&format!(
            "[{}]",
            json_layer("swaylock", "DP-2", "Overlay", "Exclusive")
        )));
        assert!(parse_layers_allows_entry_json(&format!(
            "[{}]",
            json_layer("LAN Mouse Sharing", "DP-2", "Overlay", "Exclusive")
        )));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &format!("[{}]", json_ws(42, 1, Some("DP-2"), true, true, Some(10))),
            &format!("[{}]", json_win(10, Some("w"), Some(42), false)),
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));

        // 5. V6-4 RecvError fail-closed on wait_epoch_confirmed:
        let (wtx, mut wrx) = watch::channel(0u64);
        drop(wtx);
        let outcome = wait_epoch_confirmed(
            &mut wrx,
            &obligations,
            2,
            Instant::now() + Duration::from_millis(100),
        )
        .await;
        assert_eq!(outcome, WaitEpochOutcome::DriverClosedFailClosed);
        assert_eq!(
            obligations.lock().unwrap().recovery_gate,
            RecoveryGate::ExhaustedFailClosed
        );

        // 6. V4-2 obligation_epoch race: advancing epoch during in-flight recovery prevents stale Healthy commit.
        let mut ob_race = BridgeObligations::new_startup_recovery();
        let notify = Notify::new();
        let e1 = ob_race.trigger_recovery(&notify);
        let e2 = ob_race.trigger_recovery(&notify);
        assert!(e2 > e1);
        assert_ne!(ob_race.obligation_epoch, e1);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn v7_3_pinned_from_socket_mode_restoration_and_listener_binding() {
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::{FileTypeExt, MetadataExt};
        use std::os::unix::net::UnixListener;

        let dir = temp_dir("cursor-bridge-v7-3");
        let sock_path = dir.join("wayland-0");
        let listener = UnixListener::bind(&sock_path).unwrap();
        let meta = std::fs::metadata(&sock_path).unwrap();
        assert!(meta.file_type().is_socket());

        let std_stream = StdUnixStream::connect(&sock_path).unwrap();
        let post_meta = std::fs::metadata(&sock_path).unwrap();
        assert_eq!((meta.dev(), meta.ino()), (post_meta.dev(), post_meta.ino()));

        std_stream.set_nonblocking(true).unwrap();
        let tokio_stream = tokio::net::UnixStream::from_std(std_stream).unwrap();
        let cred = tokio_stream.peer_cred().unwrap();
        assert_eq!(cred.uid(), current_euid().unwrap());
        assert!(cred.pid().unwrap() > 0);

        let std_stream = tokio_stream.into_std().unwrap();
        // into_std() leaves O_NONBLOCK set; must restore blocking mode before Connection::from_socket.
        std_stream.set_nonblocking(false).unwrap();
        let raw_fd = std_stream.as_raw_fd();
        assert!(raw_fd >= 0);

        drop(std_stream);
        drop(listener);
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn repro_code_1_7_9_10_against_frozen_production() {
        // CODE-1: run_bounded_command with small stdout and exit 0 fails due to retained Command stdout fd.
        let obligations = Arc::new(Mutex::new(BridgeObligations::new_startup_recovery()));
        let res = run_bounded_command(
            Path::new("/bin/sh"),
            &["-c", "printf 'hello-eof\n'"],
            &[],
            &obligations,
            Instant::now() + Duration::from_millis(200),
        )
        .await;
        assert_eq!(res, Ok("hello-eof\n".to_string()));

        // CODE-7: multiple surfaces in layers + missing target workspace + mismatched focused-window workspace.
        assert!(!parse_layers_allows_entry_json(&format!(
            "[{},{}]",
            json_layer("LAN Mouse Sharing", "DP-2", "Overlay", "Exclusive"),
            json_layer("rogue-lock", "DP-2", "Overlay", "Exclusive")
        )));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &format!("[{}]", json_ws(10, 1, Some("DP-1"), true, true, Some(10))),
            &format!("[{}]", json_win(10, Some("w"), Some(10), true)),
            r#"{"is_open":false}"#,
            &json_win(10, Some("w"), Some(10), true),
            "DP-2"
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &format!("[{}]", json_ws(42, 2, Some("DP-2"), true, true, Some(10))),
            &format!("[{}]", json_win(10, Some("w"), Some(42), true)),
            r#"{"is_open":false}"#,
            &json_win(99, Some("other"), Some(10), true),
            "DP-2"
        ));

        // CODE-9: Axis120 i32::MIN must return Err without overflow panic.
        assert!(validate_d5_frame(&[3, 0, 128, 0, 0, 0]).is_err());

        // CODE-10: partial readiness options on --listen and readiness options on --dial must fail.
        let partial = parse(
            [
                "--listen",
                "--quic-addr",
                "0.0.0.0:4243",
                "--lan-local",
                "127.0.0.1:4244",
                "--lan-peer",
                "127.0.0.1:4242",
                "--cert",
                "/tmp/c",
                "--key",
                "/tmp/k",
                "--enter-output",
                "DP-2",
                "--serial-floor-file",
                "/tmp/f",
                "--seat-state-file",
                "/tmp/s",
            ]
            .into_iter()
            .map(String::from),
        );
        assert!(partial.is_err());

        let dial_with_readiness = parse(
            [
                "--dial",
                "--quic-addr",
                "192.168.10.75:4243",
                "--lan-local",
                "127.0.0.1:4244",
                "--lan-peer",
                "127.0.0.1:4242",
                "--cert",
                "/tmp/c",
                "--key",
                "/tmp/k",
                "--niri-bin",
                "/bin/niri",
                "--busctl-bin",
                "/bin/busctl",
                "--enter-output",
                "DP-2",
                "--serial-floor-file",
                "/tmp/f",
                "--seat-state-file",
                "/tmp/s",
            ]
            .into_iter()
            .map(String::from),
        );
        assert!(dial_with_readiness.is_err());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn code_2_3_4_5_and_positive_mtls_splice_paths() {
        // CODE-2: both completion orders and partial timeout in await_optional_pair / drain_session_for_decision.
        let mut h_in = Some(tokio::spawn(async {}));
        let mut h_out = Some(tokio::spawn(async {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }));
        await_optional_pair(&mut h_in, &mut h_out).await;
        assert!(h_in.is_none() && h_out.is_none());

        let mut h_in2 = Some(tokio::spawn(async {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }));
        let mut h_out2 = Some(tokio::spawn(async {}));
        await_optional_pair(&mut h_in2, &mut h_out2).await;
        assert!(h_in2.is_none() && h_out2.is_none());

        // Partial timeout: inbound finishes immediately, outbound hangs until aborted; must not panic.
        let (dir_s, cert_s, key_s) = temp_cert_files();
        let server_ep = Endpoint::new(
            EndpointConfig::default(),
            Some(server_config(&cert_s, &key_s).unwrap()),
            memory_socket().0,
            Arc::new(TokioRuntime),
        )
        .unwrap();
        let listen_addr = server_ep.local_addr().unwrap();
        let mut client_ep = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        client_ep.set_default_client_config(client_config(&cert_s, &key_s).unwrap());

        let srv_accept = tokio::spawn(async move { server_ep.accept().await.unwrap().await.unwrap() });
        let cli_conn = client_ep
            .connect(listen_addr, "cursor-bridge")
            .unwrap()
            .await
            .unwrap();
        let srv_conn = srv_accept.await.unwrap();

        let (cancel_tx, _cancel_rx) = watch::channel(false);
        let mut partial_handles = Some(SpliceHandles {
            inbound: Some(tokio::spawn(async {})),
            clipboard: None,
            outbound: Some(tokio::spawn(async {
                std::future::pending::<()>().await;
            })),
            placement_slot: Arc::new(tokio::sync::Mutex::new(None)),
            conn: srv_conn.clone(),
            cancel_tx,
        });
        let demux_target = Arc::new(Mutex::new(DemuxTarget {
            active_gen: None,
            refused_until: None,
            tx: None,
            cancel_tx: None,
        }));
        let ob = Arc::new(Mutex::new(BridgeObligations {
            has_active_obligations: false,
            pressed_buttons: BTreeSet::new(),
            obligation_epoch: 1,
            recovery_gate: RecoveryGate::Healthy,
            reaper: Vec::new(),
            reserved_reaper_slots: 0,
        }));
        let notify = Arc::new(Notify::new());
        let (_ctx, mut crx) = watch::channel(1u64);
        let drain_res = drain_session_for_decision(
            &mut partial_handles,
            &demux_target,
            &ob,
            &notify,
            &mut crx,
            Instant::now() + Duration::from_millis(400),
        )
        .await;
        assert!(drain_res.is_ok());
        assert!(partial_handles.is_none());

        // CODE-3: LatestConnSlot mutex is not held across async drain.
        let latest_slot = Arc::new(Mutex::new(LatestConnSlot {
            closed: false,
            pending: None,
        }));
        latest_slot.lock().unwrap().publish(cli_conn.clone());
        let taken = { latest_slot.lock().unwrap().take() };
        assert!(taken.is_some());
        // Another thread/task can lock & publish immediately while caller is in async work.
        assert!(latest_slot.try_lock().is_ok());

        // CODE-4 & positive bidirectional mTLS splice:
        // Start a fresh mTLS QUIC pair with real spawn_splice_tasks on both sides.
        let server_ep2 = Endpoint::new(
            EndpointConfig::default(),
            Some(server_config(&cert_s, &key_s).unwrap()),
            memory_socket().0,
            Arc::new(TokioRuntime),
        )
        .unwrap();
        let listen_addr2 = server_ep2.local_addr().unwrap();
        let srv_accept2 = tokio::spawn(async move { server_ep2.accept().await.unwrap().await.unwrap() });
        let cli_conn2 = client_ep
            .connect(listen_addr2, "cursor-bridge")
            .unwrap()
            .await
            .unwrap();
        let srv_conn2 = srv_accept2.await.unwrap();

        let (ws_lan_std, ws_lan_addr) = memory_socket();
        let ws_lan = Arc::new(tokio::net::UdpSocket::from_std(ws_lan_std).unwrap());
        let (ws_peer, ws_peer_addr) = blocking_socket();

        let (vm_lan_std, vm_lan_addr) = memory_socket();
        let vm_lan = Arc::new(tokio::net::UdpSocket::from_std(vm_lan_std).unwrap());
        let (vm_peer, vm_peer_addr) = blocking_socket();

        let (ws_tx, ws_rx) = mpsc::channel(LOCAL_TO_QUIC_CAP);
        let (vm_tx, vm_rx) = mpsc::channel(LOCAL_TO_QUIC_CAP);
        let (ws_cancel_tx, ws_cancel_rx) = watch::channel(false);
        let (vm_cancel_tx, vm_cancel_rx) = watch::channel(false);

        let ws_demux_target = Arc::new(Mutex::new(DemuxTarget {
            active_gen: Some(SessionForwardTarget { session_gen: 1 }),
            refused_until: None,
            tx: Some(ws_tx.clone()),
            cancel_tx: Some(ws_cancel_tx.clone()),
        }));
        let vm_demux_target = Arc::new(Mutex::new(DemuxTarget {
            active_gen: Some(SessionForwardTarget { session_gen: 1 }),
            refused_until: None,
            tx: Some(vm_tx.clone()),
            cancel_tx: Some(vm_cancel_tx.clone()),
        }));

        let ws_ob = Arc::new(Mutex::new(BridgeObligations {
            has_active_obligations: false,
            pressed_buttons: BTreeSet::new(),
            obligation_epoch: 1,
            recovery_gate: RecoveryGate::Healthy,
            reaper: Vec::new(),
            reserved_reaper_slots: 0,
        }));
        let vm_ob = Arc::new(Mutex::new(BridgeObligations {
            has_active_obligations: false,
            pressed_buttons: BTreeSet::new(),
            obligation_epoch: 1,
            recovery_gate: RecoveryGate::Healthy,
            reaper: Vec::new(),
            reserved_reaper_slots: 0,
        }));
        let (_etx, erx) = watch::channel(1u64);

        let (sd_tx, sd_rx) = watch::channel(false);
        let ws_demux = tokio::spawn(run_local_udp_demux(
            ws_lan.clone(),
            ws_peer_addr,
            Arc::new(Mutex::new(ActiveRecoverySlot::default())),
            ws_demux_target.clone(),
            sd_rx.clone(),
        ));
        let vm_demux = tokio::spawn(run_local_udp_demux(
            vm_lan.clone(),
            vm_peer_addr,
            Arc::new(Mutex::new(ActiveRecoverySlot::default())),
            vm_demux_target.clone(),
            sd_rx,
        ));

        let (ws_in, ws_out) = spawn_splice_tasks(
            srv_conn2,
            ws_lan.clone(),
            ws_peer_addr,
            None,
            ws_ob,
            Arc::new(Notify::new()),
            erx.clone(),
            ws_rx,
            ws_demux_target,
            ws_cancel_rx,
            Arc::new(tokio::sync::Mutex::new(None)),
        );
        let (vm_in, vm_out) = spawn_splice_tasks(
            cli_conn2,
            vm_lan.clone(),
            vm_peer_addr,
            None,
            vm_ob,
            Arc::new(Notify::new()),
            erx,
            vm_rx,
            vm_demux_target,
            vm_cancel_rx,
            Arc::new(tokio::sync::Mutex::new(None)),
        );

        // Positive bidirectional forwarding over mTLS QUIC + LocalUdpDemux + spawn_splice_tasks:
        let enter_pkt = encode_control_frame(PROTO_ENTER, 0);
        vm_peer.send_to(&enter_pkt, vm_lan_addr).unwrap();
        let mut buf = [0u8; 32];
        let (n, from) = ws_peer.recv_from(&mut buf).unwrap();
        assert_eq!(&buf[..n], &enter_pkt);
        assert_eq!(from, ws_lan_addr);

        let ack_pkt = encode_control_frame(PROTO_ACK, 0);
        ws_peer.send_to(&ack_pkt, ws_lan_addr).unwrap();
        let (n, from) = vm_peer.recv_from(&mut buf).unwrap();
        assert_eq!(&buf[..n], &ack_pkt);
        assert_eq!(from, vm_lan_addr);

        // CODE-4: Ping/Pong liveness keeps session alive across >750ms pause, then motion resumes.
        for _ in 0..3 {
            tokio::time::sleep(Duration::from_millis(300)).await;
            vm_peer.send_to(&[PROTO_PING], vm_lan_addr).unwrap();
            let (n, _) = ws_peer.recv_from(&mut buf).unwrap();
            assert_eq!(&buf[..n], &[PROTO_PING]);
        }
        let mut motion = [0u8; 21];
        motion[5..13].copy_from_slice(&12.5f64.to_be_bytes());
        motion[13..21].copy_from_slice(&(-4.0f64).to_be_bytes());
        vm_peer.send_to(&motion, vm_lan_addr).unwrap();
        let (n, _) = ws_peer.recv_from(&mut buf).unwrap();
        assert_eq!(&buf[..n], &motion);

        // CODE-5: PendingPlacement with blocked NIRI_SOCKET connect enforces aggregate 250ms deadline.
        let dir_niri = temp_dir("cursor-bridge-niri-timeout");
        let missing_sock = dir_niri.join("missing.sock");
        let cfg_timeout = NiriSessionConfig {
            niri_bin: PathBuf::from("/bin/true"),
            busctl_bin: PathBuf::from("/bin/true"),
            niri_socket: missing_sock,
            enter_output: "DP-2".to_string(),
            test_placement_hold: None,
        };
        let ob_t = Arc::new(Mutex::new(BridgeObligations::new_startup_recovery()));
        assert!(verify_and_place_output(&cfg_timeout, &ob_t).await.is_err());
        std::fs::remove_dir_all(dir_niri).ok();

        let _ = sd_tx.send(true);
        let _ = ws_cancel_tx.send(true);
        let _ = vm_cancel_tx.send(true);
        ws_in.abort();
        ws_out.abort();
        vm_in.abort();
        vm_out.abort();
        let _ = ws_demux.await;
        let _ = vm_demux.await;
        std::fs::remove_dir_all(dir_s).ok();
    }

    fn write_exec_script(dir: &Path, name: &str, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(name);
        std::fs::write(&path, body).unwrap();
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms).unwrap();
        path
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn repro_r1_1_placement_task_outlives_disconnect() {
        use std::os::unix::net::UnixListener;

        let dir = temp_dir("cursor-bridge-repro-r1-1");
        let niri_sock = dir.join("niri.sock");
        let _listener = UnixListener::bind(&niri_sock).unwrap();
        let marker = dir.join("marker");
        let busctl = write_exec_script(
            &dir,
            "busctl",
            &format!(
                "#!/bin/sh\necho started >> '{}'\nsleep 0.15\necho finished >> '{}'\necho 'o \"/org/freedesktop/login1/session/_1\"'\n",
                marker.display(),
                marker.display()
            ),
        );
        let niri = write_exec_script(&dir, "niri", "#!/bin/sh\nexit 0\n");

        let (dir_c, cert_p, key_p) = temp_cert_files();
        let srv_ep = Endpoint::new(
            EndpointConfig::default(),
            Some(server_config(&cert_p, &key_p).unwrap()),
            memory_socket().0,
            Arc::new(TokioRuntime),
        )
        .unwrap();
        let addr = srv_ep.local_addr().unwrap();
        let mut cli_ep = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        cli_ep.set_default_client_config(client_config(&cert_p, &key_p).unwrap());
        let srv_accept = tokio::spawn(async move { srv_ep.accept().await.unwrap().await.unwrap() });
        let cli_conn = cli_ep.connect(addr, "cursor-bridge").unwrap().await.unwrap();
        let srv_conn = srv_accept.await.unwrap();

        let (ws_lan_std, _) = memory_socket();
        let ws_lan = Arc::new(tokio::net::UdpSocket::from_std(ws_lan_std).unwrap());
        let (_ws_peer, ws_peer_addr) = blocking_socket();
        let (_tx, rx) = mpsc::channel(LOCAL_TO_QUIC_CAP);
        let (cancel_tx, cancel_rx) = watch::channel(false);
        let demux = Arc::new(Mutex::new(DemuxTarget {
            active_gen: Some(SessionForwardTarget { session_gen: 1 }),
            refused_until: None,
            tx: None,
            cancel_tx: Some(cancel_tx.clone()),
        }));
        let ob = Arc::new(Mutex::new(BridgeObligations {
            has_active_obligations: false,
            pressed_buttons: BTreeSet::new(),
            obligation_epoch: 1,
            recovery_gate: RecoveryGate::Healthy,
            reaper: Vec::new(),
            reserved_reaper_slots: 0,
        }));
        let (_etx, erx) = watch::channel(1u64);
        let niri_cfg = Some(NiriSessionConfig {
            niri_bin: niri,
            busctl_bin: busctl,
            niri_socket: niri_sock,
            enter_output: "DP-2".to_string(),
            test_placement_hold: None,
        });

        let (in_h, out_h) = spawn_splice_tasks(
            srv_conn,
            ws_lan,
            ws_peer_addr,
            niri_cfg,
            ob.clone(),
            Arc::new(Notify::new()),
            erx,
            rx,
            demux,
            cancel_rx,
            Arc::new(tokio::sync::Mutex::new(None)),
        );

        send_quic_frame(&cli_conn, &encode_control_frame(PROTO_ENTER, 0))
            .await
            .unwrap();
        for _ in 0..40 {
            if marker.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(marker.exists(), "placement command never started");

        // Disconnect client while placement is pending: inbound exits, and placement must be cancelled!
        cli_conn.close(0u32.into(), b"disconnect");
        let in_res = tokio::time::timeout(Duration::from_millis(300), in_h).await;
        assert!(
            matches!(in_res, Ok(Ok(()))),
            "inbound task did not join cleanly on disconnect: {in_res:?}"
        );
        let _ = cancel_tx.send(true);
        let out_res = tokio::time::timeout(Duration::from_millis(300), out_h).await;
        assert!(
            matches!(out_res, Ok(Ok(()))),
            "outbound task did not join cleanly: {out_res:?}"
        );
        let mut reaped = false;
        for _ in 0..10 {
            if ob.lock().unwrap().sweep_reaper() {
                reaped = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(reaped, "child reaper must clear after SIGKILL");
        tokio::time::sleep(Duration::from_millis(200)).await;
        let contents = std::fs::read_to_string(&marker).unwrap_or_default();
        assert!(
            !contents.contains("finished"),
            "R1-1: detached placement task outlived disconnected session: {contents:?}"
        );

        std::fs::remove_dir_all(dir_c).ok();
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn repro_r1_2_buffered_input_sets_input_seen() {
        use std::os::unix::net::UnixListener;

        let dir = temp_dir("cursor-bridge-repro-r1-2");
        let niri_sock = dir.join("niri.sock");
        let _listener = UnixListener::bind(&niri_sock).unwrap();
        let uid = current_euid().unwrap();
        let busctl = write_exec_script(
            &dir,
            "busctl",
            &format!(
                "#!/bin/sh\ncase \"$*\" in\n  *GetSessionByPID*) sleep 0.04; echo 'o \"/org/freedesktop/login1/session/_1\"' ;;\n  *User*) echo '(uo) {uid} \"/org/freedesktop/login1/user/{uid}\"' ;;\n  *Active*) echo 'b true' ;;\n  *State*) echo 's \"active\"' ;;\n  *Type*) echo 's \"wayland\"' ;;\n  *Class*) echo 's \"user\"' ;;\n  *LockedHint*) echo 'b false' ;;\nesac\n"
            ),
        );
        let niri = write_exec_script(
            &dir,
            "niri",
            &format!(
                "#!/bin/sh\ncase \"$*\" in\n  'msg action focus-monitor DP-2') exit 0 ;;\n  'msg --json focused-output') printf '%s\\n' '{}' ;;\n  'msg --json layers') printf '[%s]\\n' '{}' ;;\n  'msg --json workspaces') printf '[%s]\\n' '{}' ;;\n  'msg --json windows') printf '[]\\n' ;;\n  'msg --json overview-state') printf '{{\"is_open\":false}}\\n' ;;\n  'msg --json focused-window') printf 'null\\n' ;;\n  *) exit 2 ;;\nesac\n",
                json_output("DP-2", Some((0, 0, 1440, 2560, 1.0, "Normal")), Some(0)),
                json_layer("LAN Mouse Sharing", "DP-2", "Overlay", "Exclusive"),
                json_ws(42, 1, Some("DP-2"), true, true, None),
            ),
        );

        let (dir_c, cert_p, key_p) = temp_cert_files();
        let srv_ep = Endpoint::new(
            EndpointConfig::default(),
            Some(server_config(&cert_p, &key_p).unwrap()),
            memory_socket().0,
            Arc::new(TokioRuntime),
        )
        .unwrap();
        let addr = srv_ep.local_addr().unwrap();
        let mut cli_ep = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        cli_ep.set_default_client_config(client_config(&cert_p, &key_p).unwrap());
        let srv_accept = tokio::spawn(async move { srv_ep.accept().await.unwrap().await.unwrap() });
        let cli_conn = cli_ep.connect(addr, "cursor-bridge").unwrap().await.unwrap();
        let srv_conn = srv_accept.await.unwrap();

        let (ws_lan_std, _) = memory_socket();
        let ws_lan = Arc::new(tokio::net::UdpSocket::from_std(ws_lan_std).unwrap());
        let (ws_peer, ws_peer_addr) = blocking_socket();
        let (_tx, rx) = mpsc::channel(LOCAL_TO_QUIC_CAP);
        let (cancel_tx, cancel_rx) = watch::channel(false);
        let demux = Arc::new(Mutex::new(DemuxTarget {
            active_gen: Some(SessionForwardTarget { session_gen: 1 }),
            refused_until: None,
            tx: None,
            cancel_tx: Some(cancel_tx.clone()),
        }));
        let ob = Arc::new(Mutex::new(BridgeObligations {
            has_active_obligations: false,
            pressed_buttons: BTreeSet::new(),
            obligation_epoch: 1,
            recovery_gate: RecoveryGate::Healthy,
            reaper: Vec::new(),
            reserved_reaper_slots: 0,
        }));
        let notify = Arc::new(Notify::new());
        let (etx, erx) = watch::channel(1u64);
        let niri_cfg = Some(NiriSessionConfig {
            niri_bin: niri,
            busctl_bin: busctl,
            niri_socket: niri_sock,
            enter_output: "DP-2".to_string(),
            test_placement_hold: None,
        });

        let (in_h, out_h) = spawn_splice_tasks(
            srv_conn,
            ws_lan,
            ws_peer_addr,
            niri_cfg,
            ob.clone(),
            notify.clone(),
            erx,
            rx,
            demux,
            cancel_rx,
            Arc::new(tokio::sync::Mutex::new(None)),
        );

        // Send Enter, then buffer a Button(1) press while placement is pending.
        send_quic_frame(&cli_conn, &encode_control_frame(PROTO_ENTER, 0))
            .await
            .unwrap();
        let mut btn = [0u8; 13];
        btn[0] = 1;
        btn[5..9].copy_from_slice(&272u32.to_be_bytes());
        btn[9..13].copy_from_slice(&1u32.to_be_bytes());
        send_quic_frame(&cli_conn, &btn).await.unwrap();

        let mut buf = [0u8; 32];
        let (n1, _) = ws_peer.recv_from(&mut buf).unwrap();
        assert_eq!(&buf[..n1], &encode_control_frame(PROTO_ENTER, 0));
        let (n2, _) = ws_peer.recv_from(&mut buf).unwrap();
        assert_eq!(&buf[..n2], &btn);

        // Immediately send another Enter within <150ms: must trigger recovery, NOT coalesce!
        let epoch_before = ob.lock().unwrap().obligation_epoch;
        let ob_clone = ob.clone();
        let responder = tokio::spawn(async move {
            for _ in 0..40 {
                let (gate, ep) = {
                    let g = ob_clone.lock().unwrap();
                    (g.recovery_gate, g.obligation_epoch)
                };
                if matches!(gate, RecoveryGate::RecoveryRequired { .. }) && ep > epoch_before {
                    let mut g = ob_clone.lock().unwrap();
                    g.pressed_buttons.clear();
                    g.has_active_obligations = false;
                    g.recovery_gate = RecoveryGate::Healthy;
                    let _ = etx.send_replace(ep);
                    return true;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            false
        });

        send_quic_frame(&cli_conn, &encode_control_frame(PROTO_ENTER, 0))
            .await
            .unwrap();
        assert!(
            responder.await.unwrap(),
            "R1-2: immediate Enter after replayed buffered input coalesced instead of recovering"
        );

        let _ = cancel_tx.send(true);
        let _ = in_h.await;
        let _ = out_h.await;
        std::fs::remove_dir_all(dir_c).ok();
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn repro_r1_3_malformed_niri_records_fail_closed() {
        // Malformed/legacy-text/empty/missing-field JSON inputs fail closed.
        assert!(!check_workspace_and_focus_allows_entry_json(
            &format!("[{}]", json_ws(42, 1, Some("DP-2"), true, true, None)),
            r#"[{"id":10,"workspace_id":"invalid"}]"#,
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        assert!(!parse_layers_allows_entry_json(""));
        assert!(!parse_layers_allows_entry_json("unrecognized garbage"));
        assert!(!parse_layers_allows_entry_json(
            r#"[{"namespace":"LAN Mouse Sharing","output":"DP-2","layer":"Overlay"}]"#
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &format!("[{}]", json_ws(42, 1, Some("DP-2"), true, true, None)),
            "[]",
            "Overview: unknown",
            "null",
            "DP-2"
        ));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn r1_4_readiness_enabled_pending_liveness_overflow_and_joined_cleanup() {
        use std::os::unix::net::UnixListener;

        let dir = temp_dir("cursor-bridge-r1-4");
        let niri_sock = dir.join("niri.sock");
        let _listener = UnixListener::bind(&niri_sock).unwrap();
        let uid = current_euid().unwrap();
        let busctl = write_exec_script(
            &dir,
            "busctl",
            &format!(
                "#!/bin/sh\ncase \"$*\" in\n  *GetSessionByPID*) sleep 0.04; echo 'o \"/org/freedesktop/login1/session/_1\"' ;;\n  *User*) echo '(uo) {uid} \"/org/freedesktop/login1/user/{uid}\"' ;;\n  *Active*) echo 'b true' ;;\n  *State*) echo 's \"active\"' ;;\n  *Type*) echo 's \"wayland\"' ;;\n  *Class*) echo 's \"user\"' ;;\n  *LockedHint*) echo 'b false' ;;\nesac\n"
            ),
        );
        let niri = write_exec_script(
            &dir,
            "niri",
            &format!(
                "#!/bin/sh\ncase \"$*\" in\n  'msg action focus-monitor DP-2') exit 0 ;;\n  'msg --json focused-output') printf '%s\\n' '{}' ;;\n  'msg --json layers') printf '[%s]\\n' '{}' ;;\n  'msg --json workspaces') printf '[%s,%s]\\n' '{}' '{}' ;;\n  'msg --json windows') printf '[%s]\\n' '{}' ;;\n  'msg --json overview-state') printf '{{\"is_open\":false}}\\n' ;;\n  'msg --json focused-window') printf '%s\\n' '{}' ;;\n  *) exit 2 ;;\nesac\n",
                json_output("DP-2", Some((0, 0, 1440, 2560, 1.0, "Normal")), Some(0)),
                json_layer("LAN Mouse Sharing", "DP-2", "Overlay", "Exclusive"),
                json_ws(7, 1, Some("DP-1"), true, false, None),
                json_ws(42, 1, Some("DP-2"), true, true, Some(10)),
                json_win(10, Some("w"), Some(42), true),
                json_win(10, Some("w"), Some(42), true),
            ),
        );

        let (dir_c, cert_p, key_p) = temp_cert_files();
        let srv_ep = Endpoint::new(
            EndpointConfig::default(),
            Some(server_config(&cert_p, &key_p).unwrap()),
            memory_socket().0,
            Arc::new(TokioRuntime),
        )
        .unwrap();
        let addr = srv_ep.local_addr().unwrap();
        let mut cli_ep = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        cli_ep.set_default_client_config(client_config(&cert_p, &key_p).unwrap());
        let srv_accept = tokio::spawn(async move { srv_ep.accept().await.unwrap().await.unwrap() });
        let cli_conn = cli_ep.connect(addr, "cursor-bridge").unwrap().await.unwrap();
        let srv_conn = srv_accept.await.unwrap();

        let (ws_lan_std, _) = memory_socket();
        let ws_lan = Arc::new(tokio::net::UdpSocket::from_std(ws_lan_std).unwrap());
        let (ws_peer, ws_peer_addr) = blocking_socket();
        ws_peer
            .set_read_timeout(Some(Duration::from_millis(80)))
            .unwrap();

        let (_tx, rx) = mpsc::channel(LOCAL_TO_QUIC_CAP);
        let (cancel_tx, cancel_rx) = watch::channel(false);
        let demux = Arc::new(Mutex::new(DemuxTarget {
            active_gen: Some(SessionForwardTarget { session_gen: 1 }),
            refused_until: None,
            tx: None,
            cancel_tx: Some(cancel_tx.clone()),
        }));
        let ob = Arc::new(Mutex::new(BridgeObligations {
            has_active_obligations: false,
            pressed_buttons: BTreeSet::new(),
            obligation_epoch: 1,
            recovery_gate: RecoveryGate::Healthy,
            reaper: Vec::new(),
            reserved_reaper_slots: 0,
        }));
        let notify = Arc::new(Notify::new());
        let (_etx, mut erx) = watch::channel(1u64);
        let placement_slot = Arc::new(tokio::sync::Mutex::new(None));
        let niri_cfg = NiriSessionConfig {
            niri_bin: niri,
            busctl_bin: busctl,
            niri_socket: niri_sock.clone(),
            enter_output: "DP-2".to_string(),
            test_placement_hold: None,
        };

        let (in_h, out_h) = spawn_splice_tasks(
            srv_conn.clone(),
            ws_lan,
            ws_peer_addr,
            Some(niri_cfg.clone()),
            ob.clone(),
            notify.clone(),
            erx.clone(),
            rx,
            demux.clone(),
            cancel_rx,
            placement_slot.clone(),
        );
        let mut handles = Some(SpliceHandles {
            inbound: Some(in_h),
            outbound: Some(out_h),
            clipboard: None,
            placement_slot,
            conn: srv_conn,
            cancel_tx,
        });

        // 1. PendingPlacement -> Leave cancels placement & drops buffered frames:
        send_quic_frame(&cli_conn, &encode_control_frame(PROTO_ENTER, 0))
            .await
            .unwrap();
        let mut motion = [0u8; 21];
        motion[5..13].copy_from_slice(&5.0f64.to_be_bytes());
        send_quic_frame(&cli_conn, &motion).await.unwrap();
        send_quic_frame(&cli_conn, &encode_control_frame(PROTO_LEAVE, 0))
            .await
            .unwrap();
        let mut buf = [0u8; 32];
        assert!(ws_peer.recv_from(&mut buf).is_err());

        // 2. PendingPlacement >32 overflow -> Refused:
        send_quic_frame(&cli_conn, &encode_control_frame(PROTO_ENTER, 0))
            .await
            .unwrap();
        for _ in 0..33 {
            send_quic_frame(&cli_conn, &motion).await.unwrap();
        }
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert!(demux.lock().unwrap().refused_until.is_some());
        assert!(ws_peer.recv_from(&mut buf).is_err());

        // Clear refusal via Leave, then enter Placed under real readiness:
        send_quic_frame(&cli_conn, &encode_control_frame(PROTO_LEAVE, 0))
            .await
            .unwrap();
        ws_peer
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        send_quic_frame(&cli_conn, &encode_control_frame(PROTO_ENTER, 0))
            .await
            .unwrap();
        let (n, _) = ws_peer.recv_from(&mut buf).unwrap();
        assert_eq!(&buf[..n], &encode_control_frame(PROTO_ENTER, 0));

        // 3. Held button + Ping/Pong across >750ms pause, then resumed motion delivered under Placed:
        let mut btn = [0u8; 13];
        btn[0] = 1;
        btn[5..9].copy_from_slice(&272u32.to_be_bytes());
        btn[9..13].copy_from_slice(&1u32.to_be_bytes());
        send_quic_frame(&cli_conn, &btn).await.unwrap();
        let (n, _) = ws_peer.recv_from(&mut buf).unwrap();
        assert_eq!(&buf[..n], &btn);

        for _ in 0..3 {
            tokio::time::sleep(Duration::from_millis(300)).await;
            send_quic_frame(&cli_conn, &[PROTO_PING]).await.unwrap();
            let (n, _) = ws_peer.recv_from(&mut buf).unwrap();
            assert_eq!(&buf[..n], &[PROTO_PING]);
        }
        send_quic_frame(&cli_conn, &motion).await.unwrap();
        let (n, _) = ws_peer.recv_from(&mut buf).unwrap();
        assert_eq!(&buf[..n], &motion);

        // 4. Genuinely pending slow busctl script hits aggregate 250ms PLACEMENT_BUDGET deadline (upper+lower bound):
        let slow_busctl = write_exec_script(&dir, "slow_busctl", "#!/bin/sh\nsleep 0.4\n");
        let slow_cfg = NiriSessionConfig {
            niri_bin: niri_cfg.niri_bin,
            busctl_bin: slow_busctl,
            niri_socket: niri_sock,
            enter_output: "DP-2".to_string(),
            test_placement_hold: None,
        };
        let t0 = Instant::now();
        let slow_res = verify_and_place_output(&slow_cfg, &ob).await;
        let elapsed = t0.elapsed();
        assert_eq!(slow_res, Err("command deadline expired"));
        assert!(
            elapsed >= Duration::from_millis(200) && elapsed <= Duration::from_millis(350),
            "expected bounded 250ms deadline, got {elapsed:?}"
        );

        // 5. Joined teardown via drain_session_for_decision (clearing active obligation cleanly):
        {
            let mut g = ob.lock().unwrap();
            g.pressed_buttons.clear();
            g.has_active_obligations = false;
            g.recovery_gate = RecoveryGate::Healthy;
        }
        let drain = drain_session_for_decision(
            &mut handles,
            &demux,
            &ob,
            &notify,
            &mut erx,
            Instant::now() + REPLACEMENT_DECISION_BUDGET,
        )
        .await;
        assert!(drain.is_ok());
        assert!(handles.is_none());

        std::fs::remove_dir_all(dir_c).ok();
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn repro_r2_1_placement_ownership_lost_on_abort_and_timeout() {
        // Test Case B: drain_session_for_decision times out waiting on a non-yielding placement task.
        // Under R2, remaining_placement is taken by value and dropped, and active_handles is NOT restored!
        let (dir_c, cert_p, key_p) = temp_cert_files();
        let srv_ep = Endpoint::new(
            EndpointConfig::default(),
            Some(server_config(&cert_p, &key_p).unwrap()),
            memory_socket().0,
            Arc::new(TokioRuntime),
        )
        .unwrap();
        let addr = srv_ep.local_addr().unwrap();
        let mut cli_ep = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        cli_ep.set_default_client_config(client_config(&cert_p, &key_p).unwrap());
        let srv_accept = tokio::spawn(async move { srv_ep.accept().await.unwrap().await.unwrap() });
        let _cli_conn = cli_ep.connect(addr, "cursor-bridge").unwrap().await.unwrap();
        let srv_conn = srv_accept.await.unwrap();

        let (cancel_tx, _cancel_rx) = watch::channel(false);
        // Spawn a placement task with a Drop guard that records when it actually finishes/drops.
        let (started_tx, started_rx) = oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let ph = tokio::spawn(async move {
            let _ = started_tx.send(());
            // Brief non-yielding wait on std channel so abort cannot complete until released.
            let _ = release_rx.recv_timeout(Duration::from_millis(250));
        });
        let _ = started_rx.await;

        let placement_slot = Arc::new(tokio::sync::Mutex::new(Some(ph)));
        let mut handles = Some(SpliceHandles {
            inbound: Some(tokio::spawn(async {})),
            outbound: Some(tokio::spawn(async {})),
            clipboard: None,
            placement_slot: placement_slot.clone(),
            conn: srv_conn,
            cancel_tx,
        });
        let demux = Arc::new(Mutex::new(DemuxTarget {
            active_gen: None,
            refused_until: None,
            tx: None,
            cancel_tx: None,
        }));
        let ob = Arc::new(Mutex::new(BridgeObligations {
            has_active_obligations: false,
            pressed_buttons: BTreeSet::new(),
            obligation_epoch: 1,
            recovery_gate: RecoveryGate::Healthy,
            reaper: Vec::new(),
            reserved_reaper_slots: 0,
        }));
        let notify = Arc::new(Notify::new());
        let (_etx, mut erx) = watch::channel(1u64);

        let res = drain_session_for_decision(
            &mut handles,
            &demux,
            &ob,
            &notify,
            &mut erx,
            Instant::now() + Duration::from_millis(40),
        )
        .await;
        assert_eq!(res, Err((3, b"busy_draining".as_slice())));
        // R2-1: active_handles and placement_slot must still retain ownership on busy_draining!
        assert!(
            handles.is_some(),
            "R2-1: busy_draining dropped active_handles instead of preserving ownership"
        );
        let _ = release_tx.send(());
        // Clean up after releasing.
        let drain2 = drain_session_for_decision(
            &mut handles,
            &demux,
            &ob,
            &notify,
            &mut erx,
            Instant::now() + Duration::from_millis(400),
        )
        .await;
        assert!(drain2.is_ok());
        std::fs::remove_dir_all(dir_c).ok();
    }

    #[test]
    fn repro_r2_2_title_substring_and_duplicate_workspace_id() {
        let win_misleading = json_win(10, Some(r#"Workspace ID: 2 \"misleading\""#), Some(42), true);
        let ws_list = format!("[{}]", json_ws(42, 1, Some("DP-2"), true, true, Some(10)));
        let win_list = format!("[{win_misleading}]");

        // Unfocused / null focused_window on non-empty workspace 42 must fail closed.
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_list,
            &win_list,
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        // Valid focused window with misleading "Workspace ID: 2" inside JSON title on workspace 42 must pass.
        assert!(check_workspace_and_focus_allows_entry_json(
            &ws_list,
            &win_list,
            r#"{"is_open":false}"#,
            &win_misleading,
            "DP-2"
        ));
        // Duplicate "workspace_id" JSON key in WindowDto must fail closed.
        let dup_key_win = format!(
            r#"[{{"id":10,"title":"w","app_id":"a","pid":1,"workspace_id":42,"workspace_id":99,"is_focused":true,"is_floating":false,"is_urgent":false,"layout":{{"pos_in_scrolling_layout":null,"tile_size":[1.0,1.0],"window_size":[1,1],"tile_pos_in_workspace_view":null,"window_offset_in_tile":[0.0,0.0]}},"focus_timestamp":null}}]"#
        );
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_list,
            &dup_key_win,
            r#"{"is_open":false}"#,
            &win_misleading,
            "DP-2"
        ));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn r2_3_forced_abort_during_placement_join_and_real_obligations_drain() {
        // Test forced inbound abort while placement is pending in placement_slot,
        // followed by busy_draining on non-yielding placement, recovery_unconfirmed while
        // real obligations remain active, and clean settlement once confirmed.
        let (dir_c, cert_p, key_p) = temp_cert_files();
        let srv_ep = Endpoint::new(
            EndpointConfig::default(),
            Some(server_config(&cert_p, &key_p).unwrap()),
            memory_socket().0,
            Arc::new(TokioRuntime),
        )
        .unwrap();
        let addr = srv_ep.local_addr().unwrap();
        let mut cli_ep = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        cli_ep.set_default_client_config(client_config(&cert_p, &key_p).unwrap());
        let srv_accept = tokio::spawn(async move { srv_ep.accept().await.unwrap().await.unwrap() });
        let _cli_conn = cli_ep.connect(addr, "cursor-bridge").unwrap().await.unwrap();
        let srv_conn = srv_accept.await.unwrap();

        let (started_tx, started_rx) = oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let ph = tokio::spawn(async move {
            let _ = started_tx.send(());
            let _ = release_rx.recv_timeout(Duration::from_millis(300));
        });
        let _ = started_rx.await;

        let placement_slot = Arc::new(tokio::sync::Mutex::new(Some(ph)));
        let slot_for_in = placement_slot.clone();
        let mut rx_opt: Option<(u64, oneshot::Receiver<Result<(), &'static str>>)> = None;
        let in_h = tokio::spawn(async move {
            cancel_and_join_placement(&mut rx_opt, &slot_for_in).await;
        });
        tokio::time::sleep(Duration::from_millis(20)).await;

        let (cancel_tx, _cancel_rx) = watch::channel(false);
        let mut handles = Some(SpliceHandles {
            inbound: Some(in_h),
            outbound: Some(tokio::spawn(async {})),
            clipboard: None,
            placement_slot: placement_slot.clone(),
            conn: srv_conn,
            cancel_tx,
        });
        let demux = Arc::new(Mutex::new(DemuxTarget {
            active_gen: None,
            refused_until: None,
            tx: None,
            cancel_tx: None,
        }));
        let mut ob_inner = BridgeObligations::new_startup_recovery();
        ob_inner.has_active_obligations = true;
        ob_inner.pressed_buttons.insert(272);
        let ob = Arc::new(Mutex::new(ob_inner));
        let notify = Arc::new(Notify::new());
        let (etx, mut erx) = watch::channel(0u64);

        // 1. Short deadline expires during placement join -> busy_draining, handles & placement_slot preserved!
        let r1 = drain_session_for_decision(
            &mut handles,
            &demux,
            &ob,
            &notify,
            &mut erx,
            Instant::now() + Duration::from_millis(30),
        )
        .await;
        assert_eq!(r1, Err((3, b"busy_draining".as_slice())));
        assert!(handles.is_some());
        assert!(placement_slot.lock().await.is_some());

        // 2. Release placement, but keep real obligations unconfirmed -> recovery_unconfirmed!
        let _ = release_tx.send(());
        let r2 = drain_session_for_decision(
            &mut handles,
            &demux,
            &ob,
            &notify,
            &mut erx,
            Instant::now() + Duration::from_millis(60),
        )
        .await;
        assert_eq!(r2, Err((5, b"recovery_unconfirmed".as_slice())));
        assert!(handles.is_none());
        assert!(placement_slot.lock().await.is_none());

        // 3. Confirm recovery -> drain_session_for_decision succeeds cleanly!
        {
            let mut g = ob.lock().unwrap();
            let ep = g.obligation_epoch;
            g.pressed_buttons.clear();
            g.has_active_obligations = false;
            g.recovery_gate = RecoveryGate::Healthy;
            let _ = etx.send_replace(ep);
        }
        let r3 = drain_session_for_decision(
            &mut handles,
            &demux,
            &ob,
            &notify,
            &mut erx,
            Instant::now() + Duration::from_millis(100),
        )
        .await;
        assert!(r3.is_ok());

        std::fs::remove_dir_all(dir_c).ok();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn r3_1_and_r3_2_serve_handles_placement_only_draining_recovery_and_shutdown() {
        use std::os::unix::net::UnixListener;

        let dir = temp_dir("cursor-bridge-r3-1");
        let (dir_c, cert_p, key_p) = temp_cert_files();
        let niri_sock = dir.join("niri.sock");
        let _listener = UnixListener::bind(&niri_sock).unwrap();
        let floor_file = dir.join("bridge-serial");
        let seat_file = dir.join("native-seat");
        atomic_write_file(&floor_file, "floor=0\n").unwrap();
        atomic_write_file(
            &seat_file,
            "lifetime_id=comp-1\nstate=CLEAN\nserial_established=1\n",
        )
        .unwrap();

        let uid = current_euid().unwrap();
        let busctl = write_exec_script(
            &dir,
            "busctl",
            &format!(
                "#!/bin/sh\ncase \"$*\" in\n  *GetSessionByPID*) echo 'o \"/org/freedesktop/login1/session/_1\"' ;;\n  *User*) echo '(uo) {uid} \"/org/freedesktop/login1/user/{uid}\"' ;;\n  *Active*) echo 'b true' ;;\n  *State*) echo 's \"active\"' ;;\n  *Type*) echo 's \"wayland\"' ;;\n  *Class*) echo 's \"user\"' ;;\n  *LockedHint*) echo 'b false' ;;\nesac\n"
            ),
        );
        let niri = write_exec_script(
            &dir,
            "niri",
            &format!(
                "#!/bin/sh\ncase \"$*\" in\n  'msg action focus-monitor DP-2') exit 0 ;;\n  'msg --json focused-output') printf '%s\\n' '{}' ;;\n  'msg --json layers') printf '[%s]\\n' '{}' ;;\n  'msg --json workspaces') printf '[%s,%s]\\n' '{}' '{}' ;;\n  'msg --json windows') printf '[%s]\\n' '{}' ;;\n  'msg --json overview-state') printf '{{\"is_open\":false}}\\n' ;;\n  'msg --json focused-window') printf '%s\\n' '{}' ;;\n  *) exit 2 ;;\nesac\n",
                json_output("DP-2", Some((0, 0, 1440, 2560, 1.0, "Normal")), Some(0)),
                json_layer("LAN Mouse Sharing", "DP-2", "Overlay", "Exclusive"),
                json_ws(7, 1, Some("DP-1"), true, false, None),
                json_ws(42, 1, Some("DP-2"), true, true, Some(10)),
                json_win(10, Some("w"), Some(42), true),
                json_win(10, Some("w"), Some(42), true),
            ),
        );

        // 1. Verify await_active_session handles placement-only draining (inbound=None, outbound=None) without panicking.
        let srv_ep_tmp = Endpoint::new(
            EndpointConfig::default(),
            Some(server_config(&cert_p, &key_p).unwrap()),
            memory_socket().0,
            Arc::new(TokioRuntime),
        )
        .unwrap();
        let addr_tmp = srv_ep_tmp.local_addr().unwrap();
        let mut cli_tmp = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        cli_tmp.set_default_client_config(client_config(&cert_p, &key_p).unwrap());
        let accept_tmp = tokio::spawn(async move { srv_ep_tmp.accept().await.unwrap().await.unwrap() });
        let _c_tmp = cli_tmp.connect(addr_tmp, "cursor-bridge").unwrap().await.unwrap();
        let s_tmp = accept_tmp.await.unwrap();
        let (ctx_tmp, _) = watch::channel(false);
        let ph_tmp = tokio::spawn(async {
            tokio::time::sleep(Duration::from_millis(30)).await;
        });
        let mut placement_only_handles = SpliceHandles {
            inbound: None,
            outbound: None,
            clipboard: None,
            placement_slot: Arc::new(tokio::sync::Mutex::new(Some(ph_tmp))),
            conn: s_tmp,
            cancel_tx: ctx_tmp,
        };
        await_active_session(&mut placement_only_handles).await;
        assert!(placement_only_handles.placement_slot.lock().await.is_none());

        // 2. Full production serve_with_shutdown with busy_draining, refusal, RecoveryDriver + LocalUdpDemux + held-button release + bounded shutdown.
        let (lan_peer_sock, lan_peer_addr) = blocking_socket();
        lan_peer_sock.set_nonblocking(true).unwrap();
        let lan_peer_sock = Arc::new(lan_peer_sock);
        let (quic_probe, quic_addr) = memory_socket();
        drop(quic_probe);
        let (lan_probe, lan_local_addr) = memory_socket();
        drop(lan_probe);

        let trace: Arc<Mutex<Vec<PeerTraceEvent>>> = Arc::new(Mutex::new(Vec::new()));
        let trace_clone = trace.clone();
        let peer_sock_bg = lan_peer_sock.clone();
        let (peer_stop_tx, peer_stop_rx) = watch::channel(false);
        let peer_responder = tokio::spawn(async move {
            while !*peer_stop_rx.borrow() {
                {
                    let mut guard = trace_clone.lock().unwrap();
                    drain_peer_rx_locked(&peer_sock_bg, &mut guard);
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            let mut guard = trace_clone.lock().unwrap();
            drain_peer_rx_locked(&peer_sock_bg, &mut guard);
        });

        let (hold_started_tx, hold_started_rx) = oneshot::channel();
        let (hold_release_tx, hold_release_rx) = std::sync::mpsc::channel::<()>();
        let hold = Arc::new(Mutex::new(Some((hold_started_tx, hold_release_rx))));

        let args = Args {
            role: Role::Listen,
            quic_addr,
            lan_local: lan_local_addr,
            lan_peer: lan_peer_addr,
            cert: cert_p.clone(),
            key: key_p.clone(),
            niri_bin: Some(niri),
            busctl_bin: Some(busctl),
            enter_output: Some("DP-2".to_string()),
            niri_socket: Some(niri_sock),
            serial_floor_file: floor_file,
            seat_state_file: seat_file,
            clipboard: false,
            test_placement_hold: Some(hold),
        };

        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let serve_trace = trace.clone();
        let mut serve_handle = tokio::spawn(TraceServerFuture {
            inner: Box::pin(serve_with_shutdown(args, shutdown_rx)),
            trace: serve_trace,
            completed: false,
        });

        // Wait for confirmed startup Ack(1) transmission (not merely Leave(1)).
        let mut startup_confirmed = false;
        for _ in 0..80 {
            if trace
                .lock()
                .unwrap()
                .iter()
                .any(|e| matches!(e, PeerTraceEvent::AckSent { serial: 1, ok: true }))
            {
                startup_confirmed = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(startup_confirmed, "startup Ack(1) was not confirmed before conn1");

        // Phase A: conn1 triggers Enter -> verify_and_place_output holds in non-yielding wait.
        let mut cli1 = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        cli1.set_default_client_config(client_config(&cert_p, &key_p).unwrap());
        let conn1 = cli1.connect(quic_addr, "cursor-bridge").unwrap().await.unwrap();
        send_quic_frame(&conn1, &encode_control_frame(PROTO_ENTER, 0))
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), hold_started_rx)
            .await
            .expect("placement hold never started")
            .expect("hold_started_tx dropped");

        // conn2 connects while placement is held -> serve_with_shutdown hits 500ms busy_draining and refuses conn2!
        let mut cli2 = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        cli2.set_default_client_config(client_config(&cert_p, &key_p).unwrap());
        let conn2 = cli2.connect(quic_addr, "cursor-bridge").unwrap().await.unwrap();
        let conn2_closed = tokio::time::timeout(Duration::from_secs(1), conn2.closed())
            .await
            .expect("conn2 was not refused during busy_draining");
        assert!(
            matches!(
                conn2_closed,
                quinn::ConnectionError::ApplicationClosed(quinn::ApplicationClose { error_code, .. })
                if error_code == 3u32.into()
            ),
            "expected busy_draining close (code 3), got {conn2_closed:?}"
        );
        assert!(!serve_handle.is_finished(), "serve_with_shutdown exited unexpectedly after busy_draining");

        // Explicitly release placement hold -> await_active_session + drain_session_for_decision settle cleanly.
        assert!(hold_release_tx.send(()).is_ok(), "hold_release_tx send failed");
        tokio::time::sleep(Duration::from_millis(150)).await;

        // Phase B: conn3 is authorized after settlement, delivers Enter + Button(272, 1) to lan_peer.
        {
            let mut g = trace.lock().unwrap();
            drain_peer_rx_locked(&lan_peer_sock, &mut g);
            g.push(PeerTraceEvent::Conn3Started);
        }
        let mut cli3 = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        cli3.set_default_client_config(client_config(&cert_p, &key_p).unwrap());
        let conn3 = cli3.connect(quic_addr, "cursor-bridge").unwrap().await.unwrap();
        send_quic_frame(&conn3, &encode_control_frame(PROTO_ENTER, 0))
            .await
            .unwrap();
        let mut btn = [0u8; 13];
        btn[0] = 1;
        btn[5..9].copy_from_slice(&272u32.to_be_bytes());
        btn[9..13].copy_from_slice(&1u32.to_be_bytes());
        send_quic_frame(&conn3, &btn).await.unwrap();

        let mut saw_btn_press = false;
        for _ in 0..80 {
            if trace
                .lock()
                .unwrap()
                .iter()
                .any(|e| matches!(e, PeerTraceEvent::Rx(p) if p == &btn))
            {
                saw_btn_press = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(saw_btn_press, "Button(272, 1) never reached native lan_peer");

        // Phase C: Trigger shutdown WHILE Button(272, 1) obligation is outstanding!
        // Assert bounded shutdown within 750ms integration allowance (200ms slack over nominal 500ms+50ms budgets).
        {
            let mut g = trace.lock().unwrap();
            drain_peer_rx_locked(&lan_peer_sock, &mut g);
            g.push(PeerTraceEvent::ShutdownRequested);
        }
        let t_sd = Instant::now();
        assert!(shutdown_tx.send(()).is_ok(), "shutdown_tx send failed");
        let serve_res = tokio::time::timeout(Duration::from_millis(800), &mut serve_handle)
            .await
            .expect("serve_with_shutdown exceeded bounded shutdown budget")
            .expect("serve_with_shutdown panicked");
        let sd_elapsed = t_sd.elapsed();
        assert!(serve_res.is_ok(), "serve_with_shutdown failed: {serve_res:?}");
        assert!(
            sd_elapsed <= Duration::from_millis(750),
            "shutdown took {sd_elapsed:?}, expected <= 750ms"
        );

        let _ = peer_stop_tx.send(true);
        let peer_res = peer_responder.await;
        assert!(peer_res.is_ok(), "peer_responder failed: {peer_res:?}");
        let final_trace = trace.lock().unwrap();
        let sd_serial = verify_causal_recovery_trace(&final_trace, 1)
            .expect("causal recovery trace validation failed");
        assert!(sd_serial > 1, "expected fresh shutdown serial > 1, got {sd_serial}");

        std::fs::remove_dir_all(dir_c).ok();
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn r4_2_join_timeout_checks_inner_join_error() {
        let panicked_handle = tokio::spawn(async {
            panic!("simulated task panic");
        });
        let res = tokio::time::timeout(Duration::from_millis(200), panicked_handle).await;
        assert!(res.is_ok(), "outer timeout succeeded");
        assert!(
            !matches!(res, Ok(Ok(()))),
            "R4-2: matches!(res, Ok(Ok(()))) must reject Ok(Err(JoinError))"
        );

        let clean_handle = tokio::spawn(async {});
        let ok_res = tokio::time::timeout(Duration::from_millis(200), clean_handle).await;
        assert!(matches!(ok_res, Ok(Ok(()))));
    }

    struct TraceServerFuture<F> {
        inner: std::pin::Pin<Box<F>>,
        trace: Arc<Mutex<Vec<PeerTraceEvent>>>,
        completed: bool,
    }

    impl<F: std::future::Future> std::future::Future for TraceServerFuture<F> {
        type Output = F::Output;

        fn poll(
            self: std::pin::Pin<&mut Self>,
            cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<Self::Output> {
            let this = self.get_mut();
            let mut guard = this.trace.lock().unwrap();
            let res = this.inner.as_mut().poll(cx);
            if res.is_ready() && !this.completed {
                this.completed = true;
                guard.push(PeerTraceEvent::ServerReturned);
            }
            res
        }
    }

    fn drain_peer_rx_locked(sock: &UdpSocket, guard: &mut Vec<PeerTraceEvent>) {
        let mut b = [0u8; 64];
        loop {
            match sock.recv_from(&mut b) {
                Ok((n, from)) => {
                    let pkt = b[..n].to_vec();
                    guard.push(PeerTraceEvent::Rx(pkt.clone()));
                    if n == 5 && pkt[0] == PROTO_LEAVE {
                        let serial = u32::from_be_bytes(pkt[1..5].try_into().unwrap());
                        if serial != 0 {
                            let ok = sock
                                .send_to(&encode_control_frame(PROTO_ACK, serial), from)
                                .is_ok();
                            guard.push(PeerTraceEvent::AckSent { serial, ok });
                        }
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => panic!("peer_responder recv_from failed: {e}"),
            }
        }
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    enum PeerTraceEvent {
        Rx(Vec<u8>),
        AckSent { serial: u32, ok: bool },
        Conn3Started,
        ShutdownRequested,
        ServerReturned,
    }

    fn verify_causal_recovery_trace(
        trace: &[PeerTraceEvent],
        startup_serial: u32,
    ) -> Result<u32, &'static str> {
        let conn3_idx = trace
            .iter()
            .position(|e| matches!(e, PeerTraceEvent::Conn3Started))
            .ok_or("missing Conn3Started")?;
        let sd_req_idx = trace
            .iter()
            .position(|e| matches!(e, PeerTraceEvent::ShutdownRequested))
            .ok_or("missing ShutdownRequested")?;
        let srv_ret_idx = trace
            .iter()
            .position(|e| matches!(e, PeerTraceEvent::ServerReturned))
            .ok_or("missing ServerReturned")?;
        if !(conn3_idx < sd_req_idx && sd_req_idx < srv_ret_idx) {
            return Err("invalid lifecycle marker order");
        }

        let startup_leave_idx = trace[..conn3_idx]
            .iter()
            .position(|e| {
                matches!(e, PeerTraceEvent::Rx(p) if p.len() == 5 && p[0] == PROTO_LEAVE && u32::from_be_bytes(p[1..5].try_into().unwrap()) == startup_serial)
            })
            .ok_or("missing startup Leave")?;
        let startup_ack_idx = trace[..conn3_idx]
            .iter()
            .position(|e| matches!(e, PeerTraceEvent::AckSent { serial, ok: true } if *serial == startup_serial))
            .ok_or("missing confirmed startup Ack")?;
        if startup_ack_idx <= startup_leave_idx {
            return Err("startup Ack preceded Leave");
        }

        let conn3_slice = &trace[conn3_idx + 1..sd_req_idx];
        let enter_idx = conn3_slice
            .iter()
            .position(|e| matches!(e, PeerTraceEvent::Rx(p) if p == &encode_control_frame(PROTO_ENTER, 0)))
            .ok_or("missing conn3 Enter within conn3 phase")?;
        let mut btn_press = [0u8; 13];
        btn_press[0] = 1;
        btn_press[5..9].copy_from_slice(&272u32.to_be_bytes());
        btn_press[9..13].copy_from_slice(&1u32.to_be_bytes());
        let _press_idx = conn3_slice
            .iter()
            .enumerate()
            .skip(enter_idx + 1)
            .find(|(_, e)| matches!(e, PeerTraceEvent::Rx(p) if p == &btn_press))
            .map(|(i, _)| i)
            .ok_or("missing conn3 Button(272, 1) after conn3 Enter")?;

        let max_prior_serial = trace[..sd_req_idx]
            .iter()
            .filter_map(|e| match e {
                PeerTraceEvent::Rx(p) if p.len() == 5 && p[0] == PROTO_LEAVE => {
                    Some(u32::from_be_bytes(p[1..5].try_into().unwrap()))
                }
                _ => None,
            })
            .max()
            .unwrap_or(0);

        let shutdown_slice = &trace[sd_req_idx + 1..srv_ret_idx];
        let btn_release = encode_button_release(272);
        let rel_rel_idx = shutdown_slice
            .iter()
            .position(|e| matches!(e, PeerTraceEvent::Rx(p) if p == &btn_release))
            .ok_or("missing Button(272, 0) release after ShutdownRequested")?;
        let (leave_rel_idx, sd_serial) = shutdown_slice
            .iter()
            .enumerate()
            .skip(rel_rel_idx + 1)
            .find_map(|(i, e)| match e {
                PeerTraceEvent::Rx(p) if p.len() == 5 && p[0] == PROTO_LEAVE => {
                    let s = u32::from_be_bytes(p[1..5].try_into().unwrap());
                    if s > max_prior_serial {
                        Some((i, s))
                    } else {
                        None
                    }
                }
                _ => None,
            })
            .ok_or("missing fresh Leave(serial > max_prior) before ServerReturned")?;
        let ack_rel_idx = shutdown_slice
            .iter()
            .enumerate()
            .skip(leave_rel_idx + 1)
            .find(|(_, e)| matches!(e, PeerTraceEvent::AckSent { serial, ok: true } if *serial == sd_serial))
            .map(|(i, _)| i)
            .ok_or("missing confirmed Ack(sd_serial) before ServerReturned")?;
        if ack_rel_idx <= leave_rel_idx {
            return Err("shutdown Ack preceded Leave");
        }
        Ok(sd_serial)
    }

    #[test]
    fn r5_1_causal_recovery_trace_rejects_mutations_and_accepts_valid_order() {
        let mut btn_press = [0u8; 13];
        btn_press[0] = 1;
        btn_press[5..9].copy_from_slice(&272u32.to_be_bytes());
        btn_press[9..13].copy_from_slice(&1u32.to_be_bytes());
        let btn_release = encode_button_release(272);
        let enter = encode_control_frame(PROTO_ENTER, 0);

        let valid = vec![
            PeerTraceEvent::Rx(encode_control_frame(PROTO_LEAVE, 1).to_vec()),
            PeerTraceEvent::AckSent { serial: 1, ok: true },
            PeerTraceEvent::Conn3Started,
            PeerTraceEvent::Rx(enter.to_vec()),
            PeerTraceEvent::Rx(btn_press.to_vec()),
            PeerTraceEvent::ShutdownRequested,
            PeerTraceEvent::Rx(btn_release.to_vec()),
            PeerTraceEvent::Rx(encode_control_frame(PROTO_LEAVE, 2).to_vec()),
            PeerTraceEvent::AckSent { serial: 2, ok: true },
            PeerTraceEvent::ServerReturned,
        ];
        assert_eq!(verify_causal_recovery_trace(&valid, 1), Ok(2));

        // 1. Out-of-order (release before press):
        let mut out_of_order = valid.clone();
        out_of_order.swap(4, 6);
        assert!(verify_causal_recovery_trace(&out_of_order, 1).is_err());

        // 2. Reused serial (shutdown Leave(1) == max_prior 1):
        let mut reused = valid.clone();
        reused[7] = PeerTraceEvent::Rx(encode_control_frame(PROTO_LEAVE, 1).to_vec());
        reused[8] = PeerTraceEvent::AckSent { serial: 1, ok: true };
        assert!(verify_causal_recovery_trace(&reused, 1).is_err());

        // 3. Unrelated ack (Ack(99) instead of Ack(2)):
        let mut unrelated_ack = valid.clone();
        unrelated_ack[8] = PeerTraceEvent::AckSent { serial: 99, ok: true };
        assert!(verify_causal_recovery_trace(&unrelated_ack, 1).is_err());

        // 4. Send failure (AckSent { ok: false }) & missing startup sync:
        let mut send_fail = valid.clone();
        send_fail[8] = PeerTraceEvent::AckSent { serial: 2, ok: false };
        assert!(verify_causal_recovery_trace(&send_fail, 1).is_err());

        let mut no_startup_sync = valid.clone();
        no_startup_sync[1] = PeerTraceEvent::AckSent { serial: 1, ok: false };
        assert!(verify_causal_recovery_trace(&no_startup_sync, 1).is_err());

        // 5. R6-1: Matching Ack(2) arriving AFTER ServerReturned must be rejected:
        let mut ack_after_return = valid.clone();
        ack_after_return.swap(8, 9);
        assert!(verify_causal_recovery_trace(&ack_after_return, 1).is_err());

        // 6. R6-1: Prior-session Enter (before Conn3Started) cannot satisfy conn3:
        let mut prior_enter = valid;
        prior_enter.swap(2, 3);
        assert!(verify_causal_recovery_trace(&prior_enter, 1).is_err());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn r8_1_locked_receive_records_pre_phase_datagram_before_conn3_marker() {
        let trace: Arc<Mutex<Vec<PeerTraceEvent>>> = Arc::new(Mutex::new(Vec::new()));
        let mut btn_press = [0u8; 13];
        btn_press[0] = 1;
        btn_press[5..9].copy_from_slice(&272u32.to_be_bytes());
        btn_press[9..13].copy_from_slice(&1u32.to_be_bytes());
        let btn_release = encode_button_release(272);
        let enter = encode_control_frame(PROTO_ENTER, 0);

        {
            let mut g = trace.lock().unwrap();
            g.push(PeerTraceEvent::Rx(encode_control_frame(PROTO_LEAVE, 1).to_vec()));
            g.push(PeerTraceEvent::AckSent { serial: 1, ok: true });
        }

        // Send real Enter(0) datagram BEFORE Conn3Started, then drain under trace lock before pushing Conn3Started.
        let (peer_sock, peer_addr) = blocking_socket();
        peer_sock.set_nonblocking(true).unwrap();
        let (sender_sock, _) = memory_socket();
        sender_sock.send_to(&enter, peer_addr).unwrap();
        {
            let mut g = trace.lock().unwrap();
            drain_peer_rx_locked(&peer_sock, &mut g);
            g.push(PeerTraceEvent::Conn3Started);
        }

        // Complete all remaining phases validly (conn3 press, shutdown, release, Leave(2), Ack(2), ServerReturned).
        {
            let mut g = trace.lock().unwrap();
            g.push(PeerTraceEvent::Rx(btn_press.to_vec()));
            g.push(PeerTraceEvent::ShutdownRequested);
            g.push(PeerTraceEvent::Rx(btn_release.to_vec()));
            g.push(PeerTraceEvent::Rx(encode_control_frame(PROTO_LEAVE, 2).to_vec()));
            g.push(PeerTraceEvent::AckSent { serial: 2, ok: true });
            g.push(PeerTraceEvent::ServerReturned);
        }

        let guard = trace.lock().unwrap();
        let enter_idx = guard
            .iter()
            .position(|e| matches!(e, PeerTraceEvent::Rx(p) if p == &enter))
            .expect("pre-phase Enter datagram was not recorded");
        let conn3_idx = guard
            .iter()
            .position(|e| matches!(e, PeerTraceEvent::Conn3Started))
            .expect("Conn3Started missing");
        assert!(
            enter_idx < conn3_idx,
            "pre-phase Enter ({enter_idx}) must precede Conn3Started ({conn3_idx})"
        );
        assert_eq!(
            verify_causal_recovery_trace(&guard, 1),
            Err("missing conn3 Enter within conn3 phase")
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn r8_1_trace_server_future_orders_poll_ready_before_delayed_ack_and_join() {
        let trace: Arc<Mutex<Vec<PeerTraceEvent>>> = Arc::new(Mutex::new(Vec::new()));
        let mut btn_press = [0u8; 13];
        btn_press[0] = 1;
        btn_press[5..9].copy_from_slice(&272u32.to_be_bytes());
        btn_press[9..13].copy_from_slice(&1u32.to_be_bytes());
        let btn_release = encode_button_release(272);
        let enter = encode_control_frame(PROTO_ENTER, 0);

        // Valid startup AND valid conn3 phase (Enter + press) + valid ShutdownRequested + release + Leave(2) BEFORE Poll::Ready.
        {
            let mut g = trace.lock().unwrap();
            g.push(PeerTraceEvent::Rx(encode_control_frame(PROTO_LEAVE, 1).to_vec()));
            g.push(PeerTraceEvent::AckSent { serial: 1, ok: true });
            g.push(PeerTraceEvent::Conn3Started);
            g.push(PeerTraceEvent::Rx(enter.to_vec()));
            g.push(PeerTraceEvent::Rx(btn_press.to_vec()));
            g.push(PeerTraceEvent::ShutdownRequested);
            g.push(PeerTraceEvent::Rx(btn_release.to_vec()));
        }

        let (peer_sock, peer_addr) = blocking_socket();
        peer_sock.set_nonblocking(true).unwrap();
        let (sender_sock, sender_addr) = memory_socket();

        // Receive real Leave(2) datagram BEFORE Poll::Ready, deferring Ack(2) transmission until after Poll::Ready.
        sender_sock
            .send_to(&encode_control_frame(PROTO_LEAVE, 2), peer_addr)
            .unwrap();
        {
            let mut b = [0u8; 64];
            let (n, from) = peer_sock.recv_from(&mut b).unwrap();
            assert_eq!(from, sender_addr);
            trace.lock().unwrap().push(PeerTraceEvent::Rx(b[..n].to_vec()));
        }

        // Barrier-controlled server future wrapped in TraceServerFuture.
        let (allow_srv_tx, allow_srv_rx) = oneshot::channel::<()>();
        let srv_handle = tokio::spawn(TraceServerFuture {
            inner: Box::pin(async move {
                let _ = allow_srv_rx.await;
            }),
            trace: trace.clone(),
            completed: false,
        });

        // Allow server future to reach Poll::Ready, and deterministically observe ServerReturned
        // BEFORE joining srv_handle and BEFORE sending/recording Ack(2).
        assert!(allow_srv_tx.send(()).is_ok());
        let saw_srv_ret = tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if trace
                    .lock()
                    .unwrap()
                    .iter()
                    .any(|e| matches!(e, PeerTraceEvent::ServerReturned))
                {
                    break true;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap_or(false);
        assert!(saw_srv_ret, "TraceServerFuture did not record ServerReturned on Poll::Ready");

        // Now perform real late Ack(2) send_to + outcome recording under trace lock
        // BEFORE joining srv_handle (simulating delayed join observer).
        {
            let mut g = trace.lock().unwrap();
            let ok = peer_sock
                .send_to(&encode_control_frame(PROTO_ACK, 2), sender_addr)
                .is_ok();
            g.push(PeerTraceEvent::AckSent { serial: 2, ok });
        }

        // Delayed join happens AFTER Ack(2) send/record completed.
        assert!(srv_handle.await.is_ok());

        let guard = trace.lock().unwrap();
        let srv_ret_idx = guard
            .iter()
            .position(|e| matches!(e, PeerTraceEvent::ServerReturned))
            .expect("ServerReturned missing");
        let ack2_idx = guard
            .iter()
            .position(|e| matches!(e, PeerTraceEvent::AckSent { serial: 2, ok: true }))
            .expect("AckSent(2, true) missing");
        assert!(
            srv_ret_idx < ack2_idx,
            "ServerReturned ({srv_ret_idx}) must precede late AckSent(2) ({ack2_idx})"
        );
        assert_eq!(
            verify_causal_recovery_trace(&guard, 1),
            Err("missing confirmed Ack(sd_serial) before ServerReturned")
        );
    }

    #[test]
    fn niri_26_04_json_schema_and_amendment_suite() {
        // F1: layers [] allowed vs empty stdout "" refused.
        assert!(parse_layers_allows_entry_json("[]\n"));
        assert!(!parse_layers_allows_entry_json(""));

        // F2: multi-output layers with LAN Mouse Sharing Exclusive + None/OnDemand allowed.
        let f2 = format!(
            "[{},{},{}]",
            json_layer("LAN Mouse Sharing", "DP-1", "Overlay", "Exclusive"),
            json_layer("waybar", "DP-2", "Top", "None"),
            json_layer("fuzzel", "DP-2", "Overlay", "OnDemand"),
        );
        assert!(parse_layers_allows_entry_json(&f2));

        // F3: disallowed Exclusive refused + lowercase "exclusive" and object {"Exclusive":null} rejected.
        assert!(!parse_layers_allows_entry_json(&format!(
            "[{}]",
            json_layer("swaylock", "DP-2", "Overlay", "Exclusive")
        )));
        assert!(!parse_layers_allows_entry_json(
            r#"[{"namespace":"LAN Mouse Sharing","output":"DP-2","layer":"Overlay","keyboard_interactivity":"exclusive"}]"#
        ));
        assert!(!parse_layers_allows_entry_json(
            r#"[{"namespace":"LAN Mouse Sharing","output":"DP-2","layer":"Overlay","keyboard_interactivity":{"Exclusive":null}}]"#
        ));

        // F4: overview {"is_open":true} and {"is_open":false} + text/empty/missing rejected.
        let ws_42_nonempty = format!("[{}]", json_ws(42, 1, Some("DP-2"), true, true, Some(100)));
        let win_100_unfocused = format!("[{}]", json_win(100, Some("w"), Some(42), false));
        assert!(check_workspace_and_focus_allows_entry_json(
            &ws_42_nonempty,
            &win_100_unfocused,
            r#"{"is_open":true}"#,
            "null",
            "DP-2"
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_42_nonempty,
            &win_100_unfocused,
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_42_nonempty,
            "[]",
            "Overview is open.\n",
            "null",
            "DP-2"
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_42_nonempty,
            "[]",
            "",
            "null",
            "DP-2"
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_42_nonempty,
            "[]",
            "{}",
            "null",
            "DP-2"
        ));

        // F5: NIRI-3 counterexample id=42, idx=1 with unfocused window on 42 refused under overview=false.
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_42_nonempty,
            &win_100_unfocused,
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));

        // F6 (AMEND-3): cross-output equal idx=1 + same-output repeated idx=255 (2-record and 256-record <64KiB).
        let f6_cross = format!(
            "[{},{}]",
            json_ws(10, 1, Some("DP-1"), true, false, None),
            json_ws(42, 1, Some("DP-2"), true, true, None)
        );
        assert!(check_workspace_and_focus_allows_entry_json(
            &f6_cross,
            "[]",
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        let f6_sat_two = format!(
            "[{},{}]",
            json_ws(255, 255, Some("DP-2"), true, true, None),
            json_ws(256, 255, Some("DP-2"), false, false, None)
        );
        assert!(check_workspace_and_focus_allows_entry_json(
            &f6_sat_two,
            "[]",
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        let mut ws_256 = Vec::with_capacity(256);
        for i in 1u64..=256u64 {
            let idx = u8::try_from(i).unwrap_or(u8::MAX);
            ws_256.push(json_ws(i, idx, Some("DP-2"), i == 1, i == 1, None));
        }
        let ws_256_json = format!("[{}]", ws_256.join(","));
        assert!(ws_256_json.len() < MAX_COMMAND_STDOUT_BYTES);
        assert!(check_workspace_and_focus_allows_entry_json(
            &ws_256_json,
            "[]",
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        // idx=0, same-output duplicate non-saturated idx=1, and duplicate global Workspace.id (at idx=255) refused.
        assert!(!check_workspace_and_focus_allows_entry_json(
            &format!("[{}]", json_ws(1, 0, Some("DP-2"), true, true, None)),
            "[]",
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &format!(
                "[{},{}]",
                json_ws(1, 1, Some("DP-2"), true, true, None),
                json_ws(2, 1, Some("DP-2"), false, false, None)
            ),
            "[]",
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &format!(
                "[{},{}]",
                json_ws(255, 255, Some("DP-2"), true, true, None),
                json_ws(255, 255, Some("DP-2"), false, false, None)
            ),
            "[]",
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));

        // F7: lossless u64 (0, 2^53 vs 2^53+1, u64::MAX accepted; 2^64, -1, 1.0, "1" rejected).
        let big1 = 9_007_199_254_740_993u64;
        let big2 = 9_007_199_254_740_992u64;
        let f7_ws = format!(
            "[{},{},{},{}]",
            json_ws(0, 1, Some("DP-2"), true, true, Some(u64::MAX)),
            json_ws(big1, 2, Some("DP-2"), false, false, None),
            json_ws(big2, 3, Some("DP-2"), false, false, None),
            json_ws(u64::MAX, 4, Some("DP-2"), false, false, None),
        );
        let f7_win = json_win(u64::MAX, Some("big"), Some(0), true);
        assert!(check_workspace_and_focus_allows_entry_json(
            &f7_ws,
            &format!("[{f7_win}]"),
            r#"{"is_open":false}"#,
            &f7_win,
            "DP-2"
        ));
        for bad_id in ["18446744073709551616", "-1", "1.0", "\"1\""] {
            let bad_ws = format!(
                r#"[{{"id":{bad_id},"idx":1,"name":null,"output":"DP-2","is_urgent":false,"is_active":true,"is_focused":true,"active_window_id":null}}]"#
            );
            assert!(!check_workspace_and_focus_allows_entry_json(
                &bad_ws,
                "[]",
                r#"{"is_open":false}"#,
                "null",
                "DP-2"
            ));
        }

        // F8: windows [] + focused-window null + active_window_id null -> true; windows "" -> false.
        let ws_empty = format!("[{}]", json_ws(42, 1, Some("DP-2"), true, true, None));
        assert!(check_workspace_and_focus_allows_entry_json(
            &ws_empty,
            "[]\n",
            r#"{"is_open":false}"#,
            "null\n",
            "DP-2"
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_empty,
            "",
            r#"{"is_open":false}"#,
            "null\n",
            "DP-2"
        ));

        // F9: workspace_id null allowed alongside valid focused target window; refused when target_windows empty.
        let fw_42 = json_win(100, Some("f"), Some(42), true);
        let win_unattached = json_win(99, Some("drag"), None, false);
        assert!(check_workspace_and_focus_allows_entry_json(
            &ws_42_nonempty,
            &format!("[{fw_42},{win_unattached}]"),
            r#"{"is_open":false}"#,
            &fw_42,
            "DP-2"
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_empty,
            &format!("[{win_unattached}]"),
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));

        // F10 (AMEND-1): direct decoder-level omission Err vs explicit null Ok for ALL 14 nullable fields.
        let out_base = r#"{"name":"DP-2","make":"LG","model":"27","serial":null,"physical_size":null,"modes":[],"current_mode":null,"is_custom_mode":false,"vrr_supported":false,"vrr_enabled":false,"logical":null}"#;
        assert!(serde_json::from_str::<OutputDto>(out_base).is_ok());
        for (k, v) in [
            ("serial", r#""serial":null,"#),
            ("physical_size", r#""physical_size":null,"#),
            ("current_mode", r#""current_mode":null,"#),
            ("logical", r#","logical":null"#),
        ] {
            let omitted = out_base.replace(v, "");
            assert!(
                serde_json::from_str::<OutputDto>(&omitted).is_err(),
                "OutputDto.{k} omission must fail"
            );
        }

        let ws_base = r#"{"id":1,"idx":1,"name":null,"output":null,"is_urgent":false,"is_active":true,"is_focused":true,"active_window_id":null}"#;
        assert!(serde_json::from_str::<WorkspaceDto>(ws_base).is_ok());
        for (k, v) in [
            ("name", r#""name":null,"#),
            ("output", r#""output":null,"#),
            ("active_window_id", r#","active_window_id":null"#),
        ] {
            let omitted = ws_base.replace(v, "");
            assert!(
                serde_json::from_str::<WorkspaceDto>(&omitted).is_err(),
                "WorkspaceDto.{k} omission must fail"
            );
        }

        let layout_base = r#"{"pos_in_scrolling_layout":null,"tile_size":[1.0,1.0],"window_size":[1,1],"tile_pos_in_workspace_view":null,"window_offset_in_tile":[0.0,0.0]}"#;
        assert!(serde_json::from_str::<WindowLayoutDto>(layout_base).is_ok());
        for (k, v) in [
            ("pos_in_scrolling_layout", r#""pos_in_scrolling_layout":null,"#),
            ("tile_pos_in_workspace_view", r#""tile_pos_in_workspace_view":null,"#),
        ] {
            let omitted = layout_base.replace(v, "");
            assert!(
                serde_json::from_str::<WindowLayoutDto>(&omitted).is_err(),
                "WindowLayoutDto.{k} omission must fail"
            );
        }

        let win_base = r#"{"id":1,"title":null,"app_id":null,"pid":null,"workspace_id":null,"is_focused":false,"is_floating":false,"is_urgent":false,"layout":{"pos_in_scrolling_layout":null,"tile_size":[1.0,1.0],"window_size":[1,1],"tile_pos_in_workspace_view":null,"window_offset_in_tile":[0.0,0.0]},"focus_timestamp":null}"#;
        assert!(serde_json::from_str::<WindowDto>(win_base).is_ok());
        for (k, v) in [
            ("title", r#""title":null,"#),
            ("app_id", r#""app_id":null,"#),
            ("pid", r#""pid":null,"#),
            ("workspace_id", r#""workspace_id":null,"#),
            ("focus_timestamp", r#","focus_timestamp":null"#),
        ] {
            let omitted = win_base.replace(v, "");
            assert!(
                serde_json::from_str::<WindowDto>(&omitted).is_err(),
                "WindowDto.{k} omission must fail"
            );
        }

        // Omitted active_window_id on empty-workspace readiness + duplicate-null, null-then-value, unknown, trailing.
        assert!(!check_workspace_and_focus_allows_entry_json(
            r#"[{"id":42,"idx":1,"name":null,"output":"DP-2","is_urgent":false,"is_active":true,"is_focused":true}]"#,
            "[]",
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        assert!(serde_json::from_str::<OverviewDto>(r#"{"is_open":false,"is_open":true}"#).is_err());
        assert!(serde_json::from_str::<OverviewDto>(r#"{"is_open":false,"extra":1}"#).is_err());
        assert!(serde_json::from_str::<OverviewDto>(r#"{"is_open":false} true"#).is_err());
        assert!(serde_json::from_str::<WorkspaceDto>(
            r#"{"id":1,"idx":1,"name":null,"name":null,"output":"DP-2","is_urgent":false,"is_active":true,"is_focused":true,"active_window_id":null}"#
        ).is_err());
        assert!(serde_json::from_str::<WorkspaceDto>(
            r#"{"id":1,"idx":1,"name":null,"name":"w","output":"DP-2","is_urgent":false,"is_active":true,"is_focused":true,"active_window_id":null}"#
        ).is_err());

        // F11: focused-output null, logical null, Transform "270"/"Flipped90", current_mode bounds, scale.
        assert!(!parse_focused_output_json("null", "DP-2"));
        assert!(!parse_focused_output_json(&json_output("DP-2", None, Some(0)), "DP-2"));
        assert!(parse_focused_output_json(
            &json_output("DP-2", Some((0, 0, 1440, 2560, 1.0, "270")), Some(0)),
            "DP-2"
        ));
        assert!(parse_focused_output_json(
            &json_output("DP-2", Some((0, 0, 1440, 2560, 1.0, "Flipped90")), Some(0)),
            "DP-2"
        ));
        assert!(!parse_focused_output_json(
            &json_output("DP-2", Some((0, 0, 1440, 2560, 1.0, "Normal")), Some(9)),
            "DP-2"
        ));
        assert!(!parse_focused_output_json(
            &json_output("DP-2", Some((0, 0, 1440, 2560, 0.0, "Normal")), Some(0)),
            "DP-2"
        ));

        // F12: embedded quotes/newlines and \uXXXX-escaped JSON keys/strings handled purely as data.
        let esc_title = r#"line1\n\"Workspace ID: 99\""#;
        let win_esc = json_win(10, Some(esc_title), Some(42), true);
        let ws_esc = format!(
            r#"[{{"id":42,"idx":1,"name":"DP-2\n\"x\"","\u006f\u0075\u0074\u0070\u0075\u0074":"DP-2","is_urgent":false,"is_active":true,"is_focused":true,"active_window_id":10}}]"#
        );
        assert!(check_workspace_and_focus_allows_entry_json(
            &ws_esc,
            &format!("[{win_esc}]"),
            r#"{"is_open":false}"#,
            &win_esc,
            "DP-2"
        ));

        // F13: concurrent async IPC mismatches.
        // (a) target_ws.is_focused == false -> false.
        assert!(!check_workspace_and_focus_allows_entry_json(
            &format!("[{}]", json_ws(42, 1, Some("DP-2"), true, false, None)),
            "[]",
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        // (b) active_window_id == Some(100) while windows == [] (overview=false) -> false.
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_42_nonempty,
            "[]",
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        // (c) windows has is_focused:false while focused-window == Some(100) (overview=false) -> false.
        let fw_100 = json_win(100, Some("w"), Some(42), true);
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_42_nonempty,
            &win_100_unfocused,
            r#"{"is_open":false}"#,
            &fw_100,
            "DP-2"
        ));
        // (d) active_window_id == Some(100) while focused-window == null (overview=false) -> false.
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_42_nonempty,
            &format!("[{fw_100}]"),
            r#"{"is_open":false}"#,
            "null",
            "DP-2"
        ));
        // (e) overview=true with focused-window on different workspace_id (10 != 42) -> false.
        let ws_two = format!(
            "[{},{}]",
            json_ws(10, 1, Some("DP-1"), true, false, Some(5)),
            json_ws(42, 1, Some("DP-2"), true, true, None)
        );
        let fw_on_10 = json_win(5, Some("other"), Some(10), true);
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_two,
            &format!("[{fw_on_10}]"),
            r#"{"is_open":true}"#,
            &fw_on_10,
            "DP-2"
        ));

        // F14 (AMEND-2): positional JSON arrays rejected for [true]/[false] and all 9 named object DTOs.
        assert!(serde_json::from_str::<OverviewDto>("[true]").is_err());
        assert!(serde_json::from_str::<OverviewDto>("[false]").is_err());
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_empty,
            "[]",
            "[true]",
            "null",
            "DP-2"
        ));
        assert!(!check_workspace_and_focus_allows_entry_json(
            &ws_empty,
            "[]",
            "[false]",
            "null",
            "DP-2"
        ));
        assert!(serde_json::from_str::<LayerSurfaceDto>(r#"["ns","DP-2","Overlay","None"]"#).is_err());
        assert!(serde_json::from_str::<WorkspaceDto>(r#"[1,1,null,"DP-2",false,true,true,null]"#).is_err());
        assert!(serde_json::from_str::<ModeDto>("[1440,2560,60000,true]").is_err());
        assert!(serde_json::from_str::<LogicalOutputDto>(r#"[0,0,1440,2560,1.0,"Normal"]"#).is_err());
        assert!(serde_json::from_str::<OutputDto>(r#"["DP-2","LG","27",null,null,[],null,false,false,false,null]"#).is_err());
        assert!(serde_json::from_str::<TimestampDto>("[1,0]").is_err());
        assert!(serde_json::from_str::<WindowLayoutDto>(r#"[null,[1.0,1.0],[1,1],null,[0.0,0.0]]"#).is_err());
        // Positional WindowDto with VALID object-shaped WindowLayoutDto so outer array refusal is independent:
        assert!(serde_json::from_str::<WindowDto>(&format!(
            r#"[1,null,null,null,null,false,false,false,{layout_base},null]"#
        )).is_err());
        // Nested positional ModeDto / LogicalOutputDto / WindowLayoutDto / TimestampDto inside valid outer objects:
        assert!(serde_json::from_str::<OutputDto>(
            r#"{"name":"DP-2","make":"LG","model":"27","serial":null,"physical_size":null,"modes":[[1440,2560,60000,true]],"current_mode":0,"is_custom_mode":false,"vrr_supported":false,"vrr_enabled":false,"logical":null}"#
        ).is_err());
        assert!(serde_json::from_str::<OutputDto>(
            r#"{"name":"DP-2","make":"LG","model":"27","serial":null,"physical_size":null,"modes":[],"current_mode":null,"is_custom_mode":false,"vrr_supported":false,"vrr_enabled":false,"logical":[0,0,1440,2560,1.0,"Normal"]}"#
        ).is_err());
        assert!(serde_json::from_str::<WindowDto>(
            r#"{"id":1,"title":null,"app_id":null,"pid":null,"workspace_id":null,"is_focused":false,"is_floating":false,"is_urgent":false,"layout":[null,[1.0,1.0],[1,1],null,[0.0,0.0]],"focus_timestamp":null}"#
        ).is_err());
        assert!(serde_json::from_str::<WindowDto>(&format!(
            r#"{{"id":1,"title":null,"app_id":null,"pid":null,"workspace_id":null,"is_focused":false,"is_floating":false,"is_urgent":false,"layout":{layout_base},"focus_timestamp":[1,0]}}"#
        )).is_err());
        // Wrong-arity / object for tuple fields rejected:
        assert!(serde_json::from_str::<WindowLayoutDto>(
            r#"{"pos_in_scrolling_layout":[1],"tile_size":[1.0,1.0],"window_size":[1,1],"tile_pos_in_workspace_view":null,"window_offset_in_tile":[0.0,0.0]}"#
        ).is_err());
        assert!(serde_json::from_str::<WindowLayoutDto>(
            r#"{"pos_in_scrolling_layout":null,"tile_size":{"0":1.0,"1":1.0},"window_size":[1,1],"tile_pos_in_workspace_view":null,"window_offset_in_tile":[0.0,0.0]}"#
        ).is_err());
    }
}
