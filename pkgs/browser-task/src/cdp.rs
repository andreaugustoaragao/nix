use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tungstenite::client::client_with_config;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::{Message, WebSocket};

const MAX_MESSAGE: usize = 24 * 1024 * 1024;

pub struct Cdp {
    socket: WebSocket<TcpStream>,
    next_id: u64,
    pub instance: String,
    pending_command: bool,
}

fn remaining(deadline: Instant) -> Result<Duration, String> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or_else(|| "Browser operation timed out".to_owned())
}

fn connect_loopback(port: u16, deadline: Instant) -> Result<TcpStream, String> {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let stream =
        TcpStream::connect_timeout(&address, remaining(deadline)?.min(Duration::from_secs(3)))
            .map_err(|error| format!("Managed browser unavailable on port {port}: {error}"))?;
    stream
        .set_nodelay(true)
        .map_err(|error| error.to_string())?;
    Ok(stream)
}

fn version_endpoint(port: u16, deadline: Instant) -> Result<String, String> {
    let mut stream = connect_loopback(port, deadline)?;
    stream
        .set_read_timeout(Some(remaining(deadline)?.min(Duration::from_secs(3))))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(remaining(deadline)?.min(Duration::from_secs(3))))
        .map_err(|error| error.to_string())?;
    stream
        .write_all(
            format!(
                "GET /json/version HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
            )
            .as_bytes(),
        )
        .map_err(|error| format!("Reading managed browser endpoint: {error}"))?;
    let mut bytes = Vec::new();
    let mut expected_total = None;
    loop {
        let mut chunk = [0u8; 4096];
        let count = stream.read(&mut chunk).map_err(|error| error.to_string())?;
        if count == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..count]);
        if bytes.len() > 65536 {
            return Err("Managed browser endpoint response too large".to_owned());
        }
        if expected_total.is_none() {
            if let Some(separator) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                let headers =
                    std::str::from_utf8(&bytes[..separator]).map_err(|error| error.to_string())?;
                let length = headers
                    .lines()
                    .find_map(|line| {
                        line.split_once(':')
                            .filter(|(key, _)| key.eq_ignore_ascii_case("content-length"))
                            .and_then(|(_, value)| value.trim().parse::<usize>().ok())
                    })
                    .ok_or("Managed browser endpoint omitted Content-Length")?;
                if length > 65536usize.saturating_sub(separator + 4) {
                    return Err("Managed browser endpoint response too large".to_owned());
                }
                expected_total = Some(separator + 4 + length);
            }
        }
        if expected_total.is_some_and(|total| bytes.len() >= total) {
            break;
        }
        stream
            .set_read_timeout(Some(remaining(deadline)?.min(Duration::from_secs(3))))
            .map_err(|error| error.to_string())?;
    }
    let separator = bytes
        .windows(4)
        .position(|part| part == b"\r\n\r\n")
        .ok_or("Malformed managed browser response")?;
    let headers = std::str::from_utf8(&bytes[..separator]).map_err(|error| error.to_string())?;
    if !headers.starts_with("HTTP/1.1 200 ") && !headers.starts_with("HTTP/1.0 200 ") {
        return Err("Managed browser endpoint rejected discovery".to_owned());
    }
    let total = expected_total.ok_or("Managed browser endpoint response incomplete")?;
    if bytes.len() < total {
        return Err("Managed browser endpoint response incomplete".to_owned());
    }
    let value: Value =
        serde_json::from_slice(&bytes[separator + 4..total]).map_err(|error| error.to_string())?;
    let address = value["webSocketDebuggerUrl"]
        .as_str()
        .ok_or("Managed browser endpoint missing websocket URL")?;
    let prefix = format!("ws://127.0.0.1:{port}/devtools/browser/");
    let instance = address
        .strip_prefix(&prefix)
        .ok_or("Browser returned an unexpected debugging endpoint")?;
    if !valid_token(instance) {
        return Err("Browser returned an invalid instance identifier".to_owned());
    }
    Ok(instance.to_owned())
}

pub fn valid_token(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

impl Cdp {
    pub fn current_instance(port: u16, deadline: Instant) -> Result<String, String> {
        version_endpoint(port, deadline)
    }

    pub fn connect(port: u16, deadline: Instant) -> Result<Self, String> {
        let instance = version_endpoint(port, deadline)?;
        let address = format!("ws://127.0.0.1:{port}/devtools/browser/{instance}");
        let stream = connect_loopback(port, deadline)?;
        stream
            .set_read_timeout(Some(remaining(deadline)?.min(Duration::from_secs(3))))
            .map_err(|error| error.to_string())?;
        stream
            .set_write_timeout(Some(remaining(deadline)?.min(Duration::from_secs(3))))
            .map_err(|error| error.to_string())?;
        let mut config = WebSocketConfig::default();
        config.max_frame_size = Some(MAX_MESSAGE);
        config.max_message_size = Some(MAX_MESSAGE);
        let (socket, _) = client_with_config(address, stream, Some(config))
            .map_err(|error| format!("Connecting to managed browser: {error}"))?;
        Ok(Self {
            socket,
            next_id: 0,
            instance,
            pending_command: false,
        })
    }

    pub fn has_unanswered_command(&self) -> bool {
        self.pending_command
    }

    pub fn call(
        &mut self,
        method: &str,
        params: Value,
        session: Option<&str>,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> Result<Value, String> {
        self.call_inner(method, params, session, deadline, cancel, true)
    }

    pub fn recovery_call(
        &mut self,
        method: &str,
        params: Value,
        session: Option<&str>,
        deadline: Instant,
    ) -> Result<Value, String> {
        self.call_inner(
            method,
            params,
            session,
            deadline,
            &AtomicBool::new(false),
            false,
        )
    }

    fn call_inner(
        &mut self,
        method: &str,
        params: Value,
        session: Option<&str>,
        deadline: Instant,
        cancel: &AtomicBool,
        check_global: bool,
    ) -> Result<Value, String> {
        if cancel.load(Ordering::Relaxed)
            || (check_global && crate::INTERRUPTED.load(Ordering::Relaxed))
        {
            return Err("Browser operation cancelled".to_owned());
        }
        self.next_id += 1;
        let id = self.next_id;
        let command = if let Some(session) = session {
            json!({"id":id,"method":method,"params":params,"sessionId":session})
        } else {
            json!({"id":id,"method":method,"params":params})
        };
        let text = command.to_string();
        if text.len() > 256 * 1024 {
            return Err("Browser command too large".to_owned());
        }
        self.socket
            .get_mut()
            .set_write_timeout(Some(
                remaining(deadline)
                    .map_err(|_| format!("Browser timed out during {method}"))?
                    .min(Duration::from_millis(200)),
            ))
            .map_err(|error| error.to_string())?;
        self.pending_command = true;
        self.socket
            .send(Message::Text(text.into()))
            .map_err(|error| format!("Browser connection failed during {method}: {error}"))?;
        loop {
            if cancel.load(Ordering::Relaxed)
                || (check_global && crate::INTERRUPTED.load(Ordering::Relaxed))
            {
                return Err("Browser operation cancelled".to_owned());
            }
            self.socket
                .get_mut()
                .set_read_timeout(Some(
                    remaining(deadline)
                        .map_err(|_| format!("Browser timed out during {method}"))?
                        .min(Duration::from_millis(200)),
                ))
                .map_err(|error| error.to_string())?;
            match self.socket.read() {
                Ok(message) if message.is_text() || message.is_binary() => {
                    let mut reply: Value = serde_json::from_slice(&message.into_data())
                        .map_err(|error| format!("Invalid browser reply: {error}"))?;
                    if reply["id"].as_u64() != Some(id) {
                        continue;
                    }
                    self.pending_command = false;
                    if !reply["error"].is_null() {
                        let detail = reply["error"]["message"]
                            .as_str()
                            .unwrap_or("unknown error");
                        return Err(format!("Browser rejected {method}: {detail}"));
                    }
                    return Ok(reply
                        .as_object_mut()
                        .and_then(|object| object.remove("result"))
                        .unwrap_or_else(|| json!({})));
                }
                Ok(_) => continue,
                Err(tungstenite::Error::Io(error))
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        || error.kind() == std::io::ErrorKind::TimedOut =>
                {
                    continue
                }
                Err(error) => {
                    return Err(format!(
                        "Browser connection failed during {method}: {error}"
                    ))
                }
            }
        }
    }

    pub fn pages(&mut self, deadline: Instant, cancel: &AtomicBool) -> Result<Value, String> {
        self.call("Target.getTargets", json!({}), None, deadline, cancel)
    }

    pub fn attach(
        &mut self,
        target: &str,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> Result<String, String> {
        let reply = self.call(
            "Target.attachToTarget",
            json!({"targetId":target,"flatten":true}),
            None,
            deadline,
            cancel,
        )?;
        reply["sessionId"]
            .as_str()
            .map(str::to_owned)
            .ok_or("Browser did not return a target session".to_owned())
    }
}
