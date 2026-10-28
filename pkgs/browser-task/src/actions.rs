use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use base64::Engine;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::cdp::Cdp;

const MAX_EXPRESSION: usize = 64 * 1024;
const MAX_TEXT: usize = 64 * 1024;
const MAX_RESULT: usize = 100_000;
const MAX_SCREENSHOT: usize = 16 * 1024 * 1024;
const MAX_PIXELS: u64 = 16 * 1024 * 1024;

struct BoundedCount(usize);

impl Write for BoundedCount {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0 = self.0.saturating_add(bytes.len());
        if self.0 > MAX_RESULT {
            return Err(io::Error::other("evaluate result too large"));
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
pub enum Target {
    Ref(RefTarget),
    Role(RoleTarget),
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RefTarget {
    pub r#ref: String,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RoleTarget {
    pub role: String,
    pub name: String,
    #[serde(default)]
    pub exact: bool,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema, Clone, Copy)]
#[serde(rename_all = "snake_case")]
pub enum WaitState {
    Visible,
    Hidden,
    Attached,
    Detached,
}

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Action {
    Navigate {
        url: String,
    },
    Snapshot {
        max_nodes: Option<u16>,
        max_chars: Option<u32>,
        depth: Option<u8>,
    },
    Evaluate {
        expression: String,
    },
    Click {
        target: Target,
    },
    Fill {
        target: Target,
        text: String,
    },
    Key {
        key: String,
    },
    Wait {
        target: Target,
        state: Option<WaitState>,
    },
    Scroll {
        x: i32,
        y: i32,
    },
    Viewport {
        width: u16,
        height: u16,
    },
    Screenshot {
        full_page: Option<bool>,
    },
}

impl Action {
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Navigate { .. } => "navigate",
            Self::Snapshot { .. } => "snapshot",
            Self::Evaluate { .. } => "evaluate",
            Self::Click { .. } => "click",
            Self::Fill { .. } => "fill",
            Self::Key { .. } => "key",
            Self::Wait { .. } => "wait",
            Self::Scroll { .. } => "scroll",
            Self::Viewport { .. } => "viewport",
            Self::Screenshot { .. } => "screenshot",
        }
    }
}

#[derive(Serialize, Deserialize, Default)]
pub struct RefRecord {
    pub backend_node_id: u64,
    pub loader_id: String,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Viewport {
    pub width: u16,
    pub height: u16,
}

pub struct ActionOutput {
    pub result: Value,
    pub screenshot: Option<Vec<u8>>,
}

impl ActionOutput {
    fn value(result: Value) -> Self {
        Self {
            result,
            screenshot: None,
        }
    }
}

fn checked_call(
    cdp: &mut Cdp,
    method: &str,
    params: Value,
    session: &str,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<Value, String> {
    if cancel.load(Ordering::Relaxed) {
        return Err("action cancelled".into());
    }
    if Instant::now() >= deadline {
        return Err("action timed out".into());
    }
    cdp.call(method, params, Some(session), deadline, cancel)
}

fn loader_id(
    cdp: &mut Cdp,
    session: &str,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<String, String> {
    let tree = checked_call(
        cdp,
        "Page.getFrameTree",
        json!({}),
        session,
        deadline,
        cancel,
    )?;
    tree.pointer("/frameTree/frame/loaderId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| "page has no main-frame loader".into())
}

fn validate_url(url: &str) -> Result<(), String> {
    if url == "about:blank" {
        return Ok(());
    }
    let rest = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))
        .ok_or_else(|| "navigate requires an http, https, or about:blank URL".to_string())?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.is_empty() || url.chars().any(char::is_whitespace) {
        return Err("navigate URL has no host or contains whitespace".into());
    }
    Ok(())
}

fn evaluate_internal(
    cdp: &mut Cdp,
    session: &str,
    expression: &str,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<Value, String> {
    if expression.len() > MAX_EXPRESSION {
        return Err("JavaScript expression exceeds 64 KiB".into());
    }
    let millis = deadline
        .saturating_duration_since(Instant::now())
        .as_millis()
        .clamp(1, 300_000) as u64;
    let mut response = checked_call(
        cdp,
        "Runtime.evaluate",
        json!({
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": false,
            "timeout": millis,
            "generatePreview": false
        }),
        session,
        deadline,
        cancel,
    )?;
    if let Some(exception) = response.get("exceptionDetails") {
        let description = exception
            .pointer("/exception/description")
            .or_else(|| exception.get("text"))
            .and_then(Value::as_str)
            .unwrap_or("JavaScript exception");
        return Err(format!("evaluate failed: {}", truncate(description, 500)));
    }
    let mut object = response
        .as_object_mut()
        .and_then(|map| map.remove("result"))
        .ok_or_else(|| "evaluate returned no result".to_string())?;
    if object.get("className").and_then(Value::as_str) == Some("Promise")
        || object.get("subtype").and_then(Value::as_str) == Some("promise")
    {
        return Err("evaluate returned a Promise; asynchronous evaluation is unsupported".into());
    }
    let value = object
        .as_object_mut()
        .and_then(|map| map.remove("value"))
        .unwrap_or(Value::Null);
    if serde_json::to_writer(BoundedCount(0), &value).is_err() {
        return Err("evaluate result exceeds 100,000 bytes".into());
    }
    Ok(value)
}

fn truncate(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut cut = max;
    while !s.is_char_boundary(cut) {
        cut -= 1;
    }
    &s[..cut]
}

fn ax_nodes(
    cdp: &mut Cdp,
    session: &str,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<Vec<Value>, String> {
    let mut response = checked_call(
        cdp,
        "Accessibility.getFullAXTree",
        json!({}),
        session,
        deadline,
        cancel,
    )?;
    response
        .as_object_mut()
        .and_then(|map| map.remove("nodes"))
        .and_then(|value| match value {
            Value::Array(nodes) => Some(nodes),
            _ => None,
        })
        .ok_or_else(|| "browser returned no accessibility tree".into())
}

fn ax_value<'a>(node: &'a Value, property: &str) -> &'a str {
    node.get(property)
        .and_then(|value| value.get("value"))
        .and_then(Value::as_str)
        .unwrap_or("")
}

fn ax_ignored(node: &Value) -> bool {
    node.get("ignored").and_then(Value::as_bool) == Some(true)
}

struct SnapshotLimits {
    max_nodes: Option<u16>,
    max_chars: Option<u32>,
    depth: Option<u8>,
}

fn snapshot(
    cdp: &mut Cdp,
    session: &str,
    refs: &mut BTreeMap<String, RefRecord>,
    limits: SnapshotLimits,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<ActionOutput, String> {
    refs.clear();
    let node_limit = usize::from(limits.max_nodes.unwrap_or(1500));
    let char_limit = limits.max_chars.unwrap_or(40_000) as usize;
    let depth_limit = usize::from(limits.depth.unwrap_or(12));
    if node_limit == 0
        || node_limit > 5000
        || char_limit == 0
        || char_limit > 100_000
        || depth_limit > 32
    {
        return Err("snapshot limits must be nodes 1..5000, chars 1..100000, depth 0..32".into());
    }
    let loader = loader_id(cdp, session, deadline, cancel)?;
    let nodes = ax_nodes(cdp, session, deadline, cancel)?;
    let mut by_id = HashMap::new();
    let mut children = HashSet::new();
    for (index, node) in nodes.iter().enumerate() {
        if let Some(id) = node.get("nodeId").and_then(Value::as_str) {
            by_id.insert(id.to_string(), index);
        }
        if let Some(ids) = node.get("childIds").and_then(Value::as_array) {
            for id in ids.iter().filter_map(Value::as_str) {
                children.insert(id.to_string());
            }
        }
    }
    let mut roots = Vec::new();
    for (index, node) in nodes.iter().enumerate() {
        let id = node.get("nodeId").and_then(Value::as_str).unwrap_or("");
        if !children.contains(id) {
            roots.push(index);
        }
    }
    if roots.is_empty() && !nodes.is_empty() {
        roots.push(0);
    }
    let mut stack: Vec<(usize, usize)> = roots.into_iter().rev().map(|index| (index, 0)).collect();
    let mut text = String::new();
    let mut emitted = 0;
    let mut truncated = false;
    let mut visited = HashSet::new();
    while let Some((index, level)) = stack.pop() {
        if cancel.load(Ordering::Relaxed) {
            return Err("action cancelled".into());
        }
        if !visited.insert(index) {
            continue;
        }
        if level > depth_limit {
            truncated = true;
            continue;
        }
        let node = &nodes[index];
        let ignored = ax_ignored(node);
        let next_level = if ignored { level } else { level + 1 };
        if !ignored {
            if emitted >= node_limit {
                truncated = true;
                break;
            }
            let role = ax_value(node, "role");
            let name = ax_value(node, "name");
            let mut line = format!("{}- ", "  ".repeat(level));
            let backend_id = node.get("backendDOMNodeId").and_then(Value::as_u64);
            let token = backend_id.filter(|id| *id != 0).map(|_| loop {
                let candidate = format!("r_{:032x}", rand::random::<u128>());
                if !refs.contains_key(&candidate) {
                    break candidate;
                }
            });
            if let Some(token) = &token {
                line.push_str(&format!("[ref={token}] "));
            }
            line.push_str(role);
            if !name.is_empty() {
                line.push(' ');
                line.push_str(&serde_json::to_string(truncate(name, 500)).unwrap_or_default());
            }
            line.push('\n');
            if text.len() + line.len() > char_limit {
                truncated = true;
                break;
            }
            if let (Some(id), Some(token)) = (backend_id, token) {
                refs.insert(
                    token,
                    RefRecord {
                        backend_node_id: id,
                        loader_id: loader.clone(),
                    },
                );
            }
            text.push_str(&line);
            emitted += 1;
        }
        if let Some(ids) = node.get("childIds").and_then(Value::as_array) {
            for id in ids.iter().rev().filter_map(Value::as_str) {
                if let Some(&child_index) = by_id.get(id) {
                    stack.push((child_index, next_level));
                }
            }
        }
    }
    Ok(ActionOutput::value(
        json!({"text": text, "truncated": truncated}),
    ))
}

fn role_backend(
    cdp: &mut Cdp,
    session: &str,
    target: &RoleTarget,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<Option<u64>, String> {
    if target.role.is_empty() || target.role.len() > 100 || target.name.len() > 500 {
        return Err("role target has an invalid role or name length".into());
    }
    let nodes = ax_nodes(cdp, session, deadline, cancel)?;
    let mut found = None;
    for node in &nodes {
        if ax_ignored(node) || !ax_value(node, "role").eq_ignore_ascii_case(&target.role) {
            continue;
        }
        let name = ax_value(node, "name");
        let matches = if target.exact {
            name == target.name
        } else {
            name.to_lowercase().contains(&target.name.to_lowercase())
        };
        if !matches {
            continue;
        }
        let Some(id) = node.get("backendDOMNodeId").and_then(Value::as_u64) else {
            continue;
        };
        if found.is_some() {
            return Err("role target matches multiple accessible elements".into());
        }
        found = Some(id);
    }
    Ok(found)
}

fn target_backend(
    cdp: &mut Cdp,
    session: &str,
    target: &Target,
    refs: &BTreeMap<String, RefRecord>,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<Option<u64>, String> {
    match target {
        Target::Ref(RefTarget { r#ref }) => {
            let record = refs
                .get(r#ref)
                .ok_or_else(|| "unknown or expired snapshot ref".to_string())?;
            if record.loader_id != loader_id(cdp, session, deadline, cancel)? {
                return Err("stale snapshot ref after navigation".into());
            }
            Ok(Some(record.backend_node_id))
        }
        Target::Role(role) => role_backend(cdp, session, role, deadline, cancel),
    }
}

fn inspect_node(
    cdp: &mut Cdp,
    session: &str,
    backend_id: u64,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<Value, String> {
    let resolved = checked_call(
        cdp,
        "DOM.resolveNode",
        json!({"backendNodeId": backend_id}),
        session,
        deadline,
        cancel,
    )
    .map_err(|error| {
        if error.contains("No node with given id") || error.contains("Could not find node") {
            "target node is detached".to_string()
        } else {
            error
        }
    })?;
    let object_id = resolved
        .pointer("/object/objectId")
        .and_then(Value::as_str)
        .ok_or_else(|| "target node is detached".to_string())?;
    let inspected = checked_call(
        cdp,
        "Runtime.callFunctionOn",
        json!({
            "objectId": object_id,
            "functionDeclaration": "function() { if (!(this instanceof Element) || !this.isConnected || this.ownerDocument !== document || this.ownerDocument.defaultView !== top) return {connected:false}; const r=this.getBoundingClientRect(); const s=getComputedStyle(this); const x=r.left+r.width/2,y=r.top+r.height/2; const hit=document.elementFromPoint(x,y); return {connected:true,visible:r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.visibility!=='collapse'&&Number(s.opacity)>0&&x>=0&&y>=0&&x<innerWidth&&y<innerHeight,enabled:!this.matches(':disabled')&&this.getAttribute('aria-disabled')!=='true',editable:this.matches('input:not([readonly]),textarea:not([readonly])')||this.isContentEditable,x,y,hit:!!hit&&(hit===this||this.contains(hit))}; }",
            "returnByValue": true,
            "awaitPromise": false
        }),
        session,
        deadline,
        cancel,
    )?;
    if inspected.get("exceptionDetails").is_some() {
        return Err("target node cannot be inspected in the main document".into());
    }
    inspected
        .pointer("/result/value")
        .cloned()
        .ok_or_else(|| "target inspection returned no value".into())
}

fn live_target(
    cdp: &mut Cdp,
    session: &str,
    target: &Target,
    refs: &BTreeMap<String, RefRecord>,
    editable: bool,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<(f64, f64), String> {
    let id = target_backend(cdp, session, target, refs, deadline, cancel)?
        .ok_or_else(|| "target has no accessible match".to_string())?;
    let mut state = inspect_node(cdp, session, id, deadline, cancel)?;
    if state.get("connected").and_then(Value::as_bool) != Some(true) {
        return Err("target is detached or in an unsupported frame".into());
    }
    if state.get("visible").and_then(Value::as_bool) != Some(true) {
        checked_call(
            cdp,
            "DOM.scrollIntoViewIfNeeded",
            json!({"backendNodeId":id}),
            session,
            deadline,
            cancel,
        )?;
        state = inspect_node(cdp, session, id, deadline, cancel)?;
    }
    if state.get("visible").and_then(Value::as_bool) != Some(true) {
        return Err("target is not visible".into());
    }
    if state.get("enabled").and_then(Value::as_bool) != Some(true) {
        return Err("target is disabled".into());
    }
    if editable && state.get("editable").and_then(Value::as_bool) != Some(true) {
        return Err("target is not editable".into());
    }
    if state.get("hit").and_then(Value::as_bool) != Some(true) {
        return Err("target is obscured".into());
    }
    let x = state
        .get("x")
        .and_then(Value::as_f64)
        .ok_or("target has no x coordinate")?;
    let y = state
        .get("y")
        .and_then(Value::as_f64)
        .ok_or("target has no y coordinate")?;
    Ok((x, y))
}

fn mouse_click(
    cdp: &mut Cdp,
    session: &str,
    x: f64,
    y: f64,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<(), String> {
    checked_call(
        cdp,
        "Input.dispatchMouseEvent",
        json!({"type":"mouseMoved","x":x,"y":y}),
        session,
        deadline,
        cancel,
    )?;
    checked_call(
        cdp,
        "Input.dispatchMouseEvent",
        json!({"type":"mousePressed","x":x,"y":y,"button":"left","clickCount":1}),
        session,
        deadline,
        cancel,
    )?;
    checked_call(
        cdp,
        "Input.dispatchMouseEvent",
        json!({"type":"mouseReleased","x":x,"y":y,"button":"left","clickCount":1}),
        session,
        deadline,
        cancel,
    )?;
    Ok(())
}

fn key_parts(key: &str) -> Result<(String, u8, i32, Option<String>), String> {
    let mut modifiers = 0;
    let mut parts = key.split('+').peekable();
    let mut key_name = None;
    while let Some(part) = parts.next() {
        if parts.peek().is_none() {
            key_name = Some(part);
            break;
        }
        let bit = match part {
            "Alt" => 1,
            "Control" => 2,
            "Meta" => 4,
            "Shift" => 8,
            _ => return Err("unsupported key modifier".into()),
        };
        if modifiers & bit != 0 {
            return Err("duplicate key modifier".into());
        }
        modifiers |= bit;
    }
    let name = key_name.ok_or_else(|| "empty key".to_string())?;
    let (code, text) = match name {
        "Enter" => (13, Some("\r".to_string())),
        "Tab" => (9, Some("\t".to_string())),
        "Escape" => (27, None),
        "Backspace" => (8, None),
        "Delete" => (46, None),
        "ArrowLeft" => (37, None),
        "ArrowUp" => (38, None),
        "ArrowRight" => (39, None),
        "ArrowDown" => (40, None),
        "Home" => (36, None),
        "End" => (35, None),
        "PageUp" => (33, None),
        "PageDown" => (34, None),
        "Space" => (32, Some(" ".to_string())),
        _ if name.chars().count() == 1 => {
            let ch = name.chars().next().unwrap();
            (ch.to_ascii_uppercase() as i32, Some(name.to_string()))
        }
        _ => return Err("unsupported key".into()),
    };
    let text = if modifiers & (2 | 4) == 0 { text } else { None };
    Ok((
        if name == "Space" {
            " ".into()
        } else {
            name.into()
        },
        modifiers,
        code,
        text,
    ))
}

fn dispatch_key(
    cdp: &mut Cdp,
    session: &str,
    key: &str,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<(), String> {
    let (name, modifiers, code, text) = key_parts(key)?;
    let kind = if text.is_some() {
        "keyDown"
    } else {
        "rawKeyDown"
    };
    checked_call(
        cdp,
        "Input.dispatchKeyEvent",
        json!({"type":kind,"key":name,"text":text.clone().unwrap_or_default(),"modifiers":modifiers,"windowsVirtualKeyCode":code,"nativeVirtualKeyCode":code}),
        session,
        deadline,
        cancel,
    )?;
    checked_call(
        cdp,
        "Input.dispatchKeyEvent",
        json!({"type":"keyUp","key":name,"modifiers":modifiers,"windowsVirtualKeyCode":code,"nativeVirtualKeyCode":code}),
        session,
        deadline,
        cancel,
    )?;
    Ok(())
}

fn target_state(
    cdp: &mut Cdp,
    session: &str,
    target: &Target,
    refs: &BTreeMap<String, RefRecord>,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<(bool, bool), String> {
    let Some(id) = target_backend(cdp, session, target, refs, deadline, cancel)? else {
        return Ok((false, false));
    };
    let state = match inspect_node(cdp, session, id, deadline, cancel) {
        Ok(value) => value,
        Err(error) if error == "target node is detached" => return Ok((false, false)),
        Err(error) => return Err(error),
    };
    let attached = state.get("connected").and_then(Value::as_bool) == Some(true);
    let visible = attached && state.get("visible").and_then(Value::as_bool) == Some(true);
    Ok((attached, visible))
}

fn wait_target(
    cdp: &mut Cdp,
    session: &str,
    target: &Target,
    state: WaitState,
    refs: &BTreeMap<String, RefRecord>,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<ActionOutput, String> {
    loop {
        let (attached, visible) = target_state(cdp, session, target, refs, deadline, cancel)?;
        let ready = match state {
            WaitState::Visible => visible,
            WaitState::Hidden => !visible,
            WaitState::Attached => attached,
            WaitState::Detached => !attached,
        };
        if ready {
            return Ok(ActionOutput::value(json!({"state": state})));
        }
        if cancel.load(Ordering::Relaxed) {
            return Err("action cancelled".into());
        }
        if Instant::now() >= deadline {
            return Err("wait timed out".into());
        }
        thread::sleep(
            Duration::from_millis(50).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
}

fn metrics(
    cdp: &mut Cdp,
    session: &str,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<Value, String> {
    checked_call(
        cdp,
        "Page.getLayoutMetrics",
        json!({}),
        session,
        deadline,
        cancel,
    )
}

fn metric_dimension(metrics: &Value, field: &str, full_page: bool) -> Result<u32, String> {
    let paths = if full_page {
        vec![
            format!("/cssContentSize/{field}"),
            format!("/contentSize/{field}"),
        ]
    } else {
        let name = if field == "width" {
            "clientWidth"
        } else {
            "clientHeight"
        };
        vec![
            format!("/cssVisualViewport/{name}"),
            format!("/visualViewport/{name}"),
            format!("/cssLayoutViewport/{name}"),
        ]
    };
    let number = paths
        .iter()
        .find_map(|path| metrics.pointer(path).and_then(Value::as_f64))
        .ok_or_else(|| format!("browser omitted screenshot {field}"))?;
    if !number.is_finite() || number <= 0.0 || number > 16_777_216.0 {
        return Err("invalid screenshot dimensions".into());
    }
    Ok(number.ceil() as u32)
}

fn screenshot(
    cdp: &mut Cdp,
    session: &str,
    full_page: bool,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<ActionOutput, String> {
    let capture_deadline = deadline.min(Instant::now() + Duration::from_secs(10));
    let layout = metrics(cdp, session, capture_deadline, cancel)?;
    let width = metric_dimension(&layout, "width", full_page)?;
    let height = metric_dimension(&layout, "height", full_page)?;
    if u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err("screenshot exceeds 16 megapixels".into());
    }
    let mut params = json!({"format":"png","captureBeyondViewport":full_page,"fromSurface":true});
    if full_page {
        params["clip"] = json!({"x":0,"y":0,"width":width,"height":height,"scale":1});
    }
    let response = checked_call(
        cdp,
        "Page.captureScreenshot",
        params,
        session,
        capture_deadline,
        cancel,
    )
    .map_err(|error| format!("background screenshot unavailable: {error}"))?;
    let encoded = response
        .get("data")
        .and_then(Value::as_str)
        .ok_or_else(|| "browser returned no screenshot data".to_string())?;
    if encoded.len() > (MAX_SCREENSHOT * 4 / 3 + 4) {
        return Err("screenshot exceeds 16 MiB".into());
    }
    let png = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| "browser returned invalid screenshot data".to_string())?;
    if png.len() > MAX_SCREENSHOT
        || png.len() < 24
        || !png.starts_with(b"\x89PNG\r\n\x1a\n")
        || &png[12..16] != b"IHDR"
    {
        return Err("browser returned an oversized or invalid PNG screenshot".into());
    }
    let png_width = u32::from_be_bytes(png[16..20].try_into().unwrap());
    let png_height = u32::from_be_bytes(png[20..24].try_into().unwrap());
    if png_width == 0
        || png_height == 0
        || u64::from(png_width) * u64::from(png_height) > MAX_PIXELS
    {
        return Err("screenshot exceeds 16 megapixels".into());
    }
    Ok(ActionOutput {
        result: json!({"mime":"image/png","bytes":png.len(),"width":png_width,"height":png_height,"full_page":full_page}),
        screenshot: Some(png),
    })
}

pub fn execute(
    cdp: &mut Cdp,
    session: &str,
    action: &Action,
    refs: &mut BTreeMap<String, RefRecord>,
    viewport: &mut Option<Viewport>,
    deadline: Instant,
    cancel: &AtomicBool,
) -> Result<ActionOutput, String> {
    match action {
        Action::Navigate { url } => {
            refs.clear();
            validate_url(url)?;
            let response = checked_call(
                cdp,
                "Page.navigate",
                json!({"url":url}),
                session,
                deadline,
                cancel,
            )?;
            if let Some(error) = response.get("errorText").and_then(Value::as_str) {
                return Err(format!("navigation failed: {}", truncate(error, 500)));
            }
            let expected_loader = response
                .get("loaderId")
                .and_then(Value::as_str)
                .map(str::to_owned);
            loop {
                if let Ok(current_loader) = loader_id(cdp, session, deadline, cancel) {
                    if expected_loader
                        .as_ref()
                        .is_none_or(|id| id == &current_loader)
                    {
                        if let Ok(value) = evaluate_internal(
                            cdp,
                            session,
                            "({readyState:document.readyState,url:location.href,domContentLoadedEnd:performance.getEntriesByType('navigation')[0]?.domContentLoadedEventEnd??0})",
                            deadline,
                            cancel,
                        ) {
                            let ready = value
                                .get("readyState")
                                .and_then(Value::as_str)
                                .unwrap_or("");
                            let dom_content_loaded = value.get("domContentLoadedEnd").and_then(Value::as_f64).unwrap_or(0.0) > 0.0;
                            if expected_loader.is_none() || ready == "complete" || dom_content_loaded {
                                return Ok(ActionOutput::value(
                                    json!({"url":value.get("url").cloned().unwrap_or(Value::Null)}),
                                ));
                            }
                        }
                    }
                }
                if cancel.load(Ordering::Relaxed) {
                    return Err("action cancelled".into());
                }
                if Instant::now() >= deadline {
                    return Err("navigation timed out".into());
                }
                thread::sleep(
                    Duration::from_millis(50)
                        .min(deadline.saturating_duration_since(Instant::now())),
                );
            }
        }
        Action::Snapshot {
            max_nodes,
            max_chars,
            depth,
        } => snapshot(
            cdp,
            session,
            refs,
            SnapshotLimits {
                max_nodes: *max_nodes,
                max_chars: *max_chars,
                depth: *depth,
            },
            deadline,
            cancel,
        ),
        Action::Evaluate { expression } => Ok(ActionOutput::value(
            json!({"value":evaluate_internal(cdp, session, expression, deadline, cancel)?}),
        )),
        Action::Click { target } => {
            let (x, y) = live_target(cdp, session, target, refs, false, deadline, cancel)?;
            mouse_click(cdp, session, x, y, deadline, cancel)?;
            Ok(ActionOutput::value(json!({"ok":true})))
        }
        Action::Fill { target, text } => {
            if text.len() > MAX_TEXT {
                return Err("fill text exceeds 64 KiB".into());
            }
            let (x, y) = live_target(cdp, session, target, refs, true, deadline, cancel)?;
            mouse_click(cdp, session, x, y, deadline, cancel)?;
            dispatch_key(cdp, session, "Control+a", deadline, cancel)?;
            if text.is_empty() {
                dispatch_key(cdp, session, "Backspace", deadline, cancel)?;
            } else {
                checked_call(
                    cdp,
                    "Input.insertText",
                    json!({"text":text}),
                    session,
                    deadline,
                    cancel,
                )?;
            }
            Ok(ActionOutput::value(json!({"ok":true})))
        }
        Action::Key { key } => {
            dispatch_key(cdp, session, key, deadline, cancel)?;
            Ok(ActionOutput::value(json!({"ok":true})))
        }
        Action::Wait { target, state } => wait_target(
            cdp,
            session,
            target,
            state.unwrap_or(WaitState::Visible),
            refs,
            deadline,
            cancel,
        ),
        Action::Scroll { x, y } => {
            let layout = metrics(cdp, session, deadline, cancel)?;
            let cx = metric_dimension(&layout, "width", false)? / 2;
            let cy = metric_dimension(&layout, "height", false)? / 2;
            checked_call(
                cdp,
                "Input.dispatchMouseEvent",
                json!({"type":"mouseWheel","x":cx,"y":cy,"deltaX":x,"deltaY":y}),
                session,
                deadline,
                cancel,
            )?;
            Ok(ActionOutput::value(json!({"ok":true})))
        }
        Action::Viewport { width, height } => {
            if !(320..=4096).contains(width) || !(320..=4096).contains(height) {
                return Err("viewport width and height must be 320..4096".into());
            }
            checked_call(
                cdp,
                "Emulation.setDeviceMetricsOverride",
                json!({"width":width,"height":height,"deviceScaleFactor":1,"mobile":false}),
                session,
                deadline,
                cancel,
            )?;
            *viewport = Some(Viewport {
                width: *width,
                height: *height,
            });
            Ok(ActionOutput::value(json!({"width":width,"height":height})))
        }
        Action::Screenshot { full_page } => {
            screenshot(cdp, session, full_page.unwrap_or(false), deadline, cancel)
        }
    }
}
