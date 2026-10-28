mod actions;
mod cdp;
mod registry;

use std::collections::{BTreeMap, HashMap};
use std::env;
use std::fs;
use std::fs::File;
use std::io::{self, BufRead, Read, Write};
use std::os::fd::FromRawFd;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use actions::Action;
use registry::{Profile, Registry};

pub static INTERRUPTED: AtomicBool = AtomicBool::new(false);

extern "C" fn interrupt(_signal: libc::c_int) {
    INTERRUPTED.store(true, Ordering::SeqCst);
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct ActionRequest {
    task: String,
    action: Action,
    #[serde(default = "default_page")]
    #[schemars(default = "default_page")]
    page: String,
    #[serde(default = "default_timeout")]
    #[schemars(default = "default_timeout")]
    #[schemars(range(min = 1, max = 300))]
    timeout: u16,
}

fn default_page() -> String {
    "main".to_owned()
}
fn default_timeout() -> u16 {
    30
}

#[derive(Default)]
struct Options {
    config: Option<PathBuf>,
    state_dir: Option<PathBuf>,
    niri: Option<String>,
    hyprctl: Option<String>,
    fuzzel: Option<String>,
    positional: Vec<String>,
}

fn schema() -> Value {
    serde_json::to_value(schemars::schema_for!(ActionRequest)).unwrap_or_else(|_| json!({}))
}

fn parse_args() -> Result<Options, String> {
    let mut options = Options::default();
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--config" => {
                options.config = Some(PathBuf::from(args.next().ok_or("--config needs a path")?))
            }
            "--state-dir" => {
                options.state_dir = Some(PathBuf::from(
                    args.next().ok_or("--state-dir needs a path")?,
                ))
            }
            "--niri" => options.niri = Some(args.next().ok_or("--niri needs a command")?),
            "--hyprctl" => options.hyprctl = Some(args.next().ok_or("--hyprctl needs a command")?),
            "--fuzzel" => options.fuzzel = Some(args.next().ok_or("--fuzzel needs a command")?),
            "--dev-browser" => {
                return Err(
                    "--dev-browser is no longer supported; use browser-task action".to_owned(),
                )
            }
            _ => options.positional.push(arg),
        }
    }
    Ok(options)
}

fn option<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].as_str())
}

fn state_dir() -> PathBuf {
    if let Some(state) = env::var_os("XDG_STATE_HOME") {
        PathBuf::from(state).join("browser-tasks")
    } else {
        PathBuf::from(env::var_os("HOME").unwrap_or_default()).join(".local/state/browser-tasks")
    }
}

fn registry(options: &Options) -> Result<Registry, String> {
    let path = options.config.as_ref().ok_or("--config is required")?;
    let bytes =
        fs::read(path).map_err(|error| format!("Cannot read managed browser config: {error}"))?;
    if bytes.len() > 65536 {
        return Err("Managed browser config is too large".to_owned());
    }
    let profiles: BTreeMap<String, Profile> = serde_json::from_slice(&bytes)
        .map_err(|error| format!("Invalid managed browser config: {error}"))?;
    Registry::new(
        options.state_dir.clone().unwrap_or_else(state_dir),
        profiles,
    )
}

fn action_from_stdin(id: &str, args: &[String]) -> Result<ActionRequest, String> {
    let mut bytes = Vec::new();
    io::stdin()
        .take(256 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() > 256 * 1024 {
        return Err("Action input exceeds 256 KiB".to_owned());
    }
    let action: Action =
        serde_json::from_slice(&bytes).map_err(|error| format!("Invalid action: {error}"))?;
    let timeout = option(args, "--timeout")
        .unwrap_or("30")
        .parse::<u16>()
        .map_err(|_| "Timeout must be 1–300 seconds")?;
    let request = ActionRequest {
        task: id.to_owned(),
        action,
        page: option(args, "--page").unwrap_or("main").to_owned(),
        timeout,
    };
    validate_request(&request)?;
    Ok(request)
}

fn validate_request(request: &ActionRequest) -> Result<(), String> {
    if !(1..=300).contains(&request.timeout) {
        return Err("Timeout must be 1–300 seconds".to_owned());
    }
    if !cdp::valid_token(&request.page) {
        return Err("Invalid task page name".to_owned());
    }
    Ok(())
}

fn execute(
    registry: &Registry,
    request: &ActionRequest,
    cancel: &AtomicBool,
) -> Result<Value, String> {
    validate_request(request)?;
    registry.action(
        &request.task,
        &request.page,
        &request.action,
        Instant::now() + Duration::from_secs(request.timeout.into()),
        cancel,
    )
}

fn cli(options: &Options, registry: &Registry) -> Result<Option<Value>, String> {
    let args = &options.positional;
    let command = args
        .first()
        .map(String::as_str)
        .ok_or("Expected a browser-task command")?;
    let deadline = Instant::now() + Duration::from_secs(30);
    let id = || {
        args.get(1)
            .map(String::as_str)
            .ok_or("Expected a task UUID")
    };
    let result = match command {
        "start" => {
            let profile = id()?;
            let label = option(args, "--label").ok_or("--label is required")?;
            registry.start(
                profile,
                label,
                option(args, "--url"),
                deadline,
                &INTERRUPTED,
            )?
        }
        "open" => registry.open(
            id()?,
            option(args, "--page").unwrap_or("main"),
            option(args, "--url"),
            deadline,
            &INTERRUPTED,
        )?,
        "info" => registry.info(id()?, deadline)?,
        "list" => registry.list(),
        "keep" | "resume" | "finish" => {
            registry.transition(id()?, command, deadline, &INTERRUPTED)?
        }
        "cleanup" => registry.cleanup(deadline, &INTERRUPTED),
        "action" => {
            let request = action_from_stdin(id()?, args)?;
            execute(registry, &request, &INTERRUPTED)?
        }
        "show" => {
            show(options, registry, args)?;
            return Ok(None);
        }
        _ => return Err(format!("Unknown browser-task command: {command}")),
    };
    Ok(Some(result))
}

fn process(command: &str, args: &[&str], input: Option<&str>) -> Result<String, String> {
    let mut child = Command::new(command)
        .args(args)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("Browser display command failed: {error}"))?;
    if let Some(input) = input {
        child
            .stdin
            .take()
            .ok_or("Browser display command input unavailable")?
            .write_all(input.as_bytes())
            .map_err(|error| error.to_string())?;
    }
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Some(status) = child.try_wait().map_err(|error| error.to_string())? {
            if !status.success() {
                return Err("Browser display command failed".to_owned());
            }
            let mut output = String::new();
            child
                .stdout
                .take()
                .ok_or("Browser display output unavailable")?
                .take(256 * 1024)
                .read_to_string(&mut output)
                .map_err(|error| error.to_string())?;
            return Ok(output);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err("Browser display command timed out".to_owned());
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn focus_window(options: &Options, app_id: &str, title: &str) -> Result<(), String> {
    let desktop = env::var("XDG_CURRENT_DESKTOP")
        .unwrap_or_default()
        .to_lowercase();
    let niri = desktop.contains("niri")
        || (!desktop.contains("hyprland") && env::var_os("NIRI_SOCKET").is_some());
    let hyprland =
        desktop.contains("hyprland") || env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some();
    if !niri && !hyprland {
        return Err("Showing a browser requires a Niri or Hyprland desktop session".to_owned());
    }
    if niri {
        let command = options.niri.as_deref().unwrap_or("niri");
        let value: Value =
            serde_json::from_str(&process(command, &["msg", "--json", "windows"], None)?)
                .map_err(|error| error.to_string())?;
        let matches = matching_windows(&value, "app_id", app_id, title);
        if matches.len() != 1 {
            return Err("Cannot identify a unique browser window; task is kept. Select it in your window switcher".to_owned());
        }
        let id = matches[0]["id"].to_string();
        process(
            command,
            &["msg", "action", "focus-window", "--id", &id],
            None,
        )?;
    } else {
        let command = options.hyprctl.as_deref().unwrap_or("hyprctl");
        let value: Value = serde_json::from_str(&process(command, &["-j", "clients"], None)?)
            .map_err(|error| error.to_string())?;
        let matches = matching_windows(&value, "class", app_id, title);
        if matches.len() != 1 {
            return Err("Cannot identify a unique browser window; task is kept. Select it in your window switcher".to_owned());
        }
        let address = matches[0]["address"]
            .as_str()
            .ok_or("Browser window lacks an address")?;
        process(
            command,
            &["dispatch", "focuswindow", &format!("address:{address}")],
            None,
        )?;
    }
    Ok(())
}

fn matching_windows<'a>(value: &'a Value, key: &str, app_id: &str, title: &str) -> Vec<&'a Value> {
    let mut matches = value
        .as_array()
        .into_iter()
        .flatten()
        .filter(|window| window[key] == app_id)
        .collect::<Vec<_>>();
    if matches.len() > 1 {
        matches.retain(|window| {
            window["title"] == title || window["title"] == format!("{title} - Chromium")
        });
    }
    matches
}

fn show(options: &Options, registry: &Registry, args: &[String]) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(30);
    if let Some(id) = args.get(1).filter(|value| !value.starts_with("--")) {
        let (profile, title, _) = registry.show_owned(
            id,
            option(args, "--page").unwrap_or("main"),
            deadline,
            &INTERRUPTED,
        )?;
        focus_window(options, &registry.profiles[&profile].app_id, &title)?;
    } else {
        let profile_filter = option(args, "--profile");
        if let Some(profile) = profile_filter {
            registry
                .profiles
                .get(profile)
                .ok_or("Unknown managed browser profile")?
                .require_window()?;
        } else if registry.profiles.values().all(|profile| profile.headless) {
            return Err(
                "All browser profiles are headless; inspect them with screenshot actions"
                    .to_owned(),
            );
        }
        let mut choices = BTreeMap::new();
        for (profile, settings) in &registry.profiles {
            if settings.headless || profile_filter.is_some_and(|filter| filter != profile) {
                continue;
            }
            let Ok(mut browser) = cdp::Cdp::connect(settings.port, deadline) else {
                continue;
            };
            let Ok(reply) = browser.pages(deadline, &INTERRUPTED) else {
                continue;
            };
            for item in reply["targetInfos"].as_array().into_iter().flatten() {
                if item["type"] != "page" {
                    continue;
                }
                let Some(target) = item["targetId"].as_str() else {
                    continue;
                };
                let title = item["title"]
                    .as_str()
                    .unwrap_or("Blank tab")
                    .replace(['\n', '\t'], " ");
                choices.insert(
                    format!("{profile}:{target}"),
                    (
                        profile.clone(),
                        target.to_owned(),
                        browser.instance.clone(),
                        title,
                    ),
                );
            }
        }
        if choices.is_empty() {
            return Err(
                "No managed browser tabs are available; check agent-browser services".to_owned(),
            );
        }
        let menu = choices
            .iter()
            .map(|(key, (profile, _, _, title))| format!("{key}\t{profile}: {title}\n"))
            .collect::<String>();
        let selection = process(
            options.fuzzel.as_deref().unwrap_or("fuzzel"),
            &[
                "--dmenu",
                "--prompt=Agent browser: ",
                "--with-nth=2",
                "--accept-nth=1",
            ],
            Some(&menu),
        )?;
        let Some((profile, target, instance, title)) = choices.get(selection.trim()) else {
            return Ok(());
        };
        registry.keep_matching_target(profile, instance, target, deadline)?;
        let mut browser = cdp::Cdp::connect(registry.profiles[profile].port, deadline)?;
        if browser.instance != *instance {
            return Err(
                "Browser restarted while selecting a tab; open the viewer again".to_owned(),
            );
        }
        browser.call(
            "Target.activateTarget",
            json!({"targetId":target}),
            None,
            deadline,
            &INTERRUPTED,
        )?;
        focus_window(options, &registry.profiles[profile].app_id, title)?;
    }
    println!("Browser shown. Managed tasks are kept until you explicitly resume and finish them.");
    Ok(())
}

fn read_line_limited<R: BufRead>(
    reader: &mut R,
    limit: usize,
    fd: libc::c_int,
) -> io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    let mut overflow = false;
    loop {
        if INTERRUPTED.load(Ordering::SeqCst) {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "MCP interrupted",
            ));
        }
        let buffer = match reader.fill_buf() {
            Ok(buffer) => buffer,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let mut descriptor = libc::pollfd {
                    fd,
                    events: libc::POLLIN,
                    revents: 0,
                };
                unsafe {
                    libc::poll(&mut descriptor, 1, 100);
                }
                continue;
            }
            Err(error) => return Err(error),
        };
        if buffer.is_empty() {
            return if overflow {
                Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "MCP input exceeds 256 KiB",
                ))
            } else if line.is_empty() {
                Ok(None)
            } else {
                Ok(Some(line))
            };
        }
        let end = buffer
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|index| index + 1);
        let count = end.unwrap_or(buffer.len());
        if !overflow && line.len() + count <= limit {
            line.extend_from_slice(&buffer[..count]);
        } else {
            overflow = true;
            line.clear();
        }
        reader.consume(count);
        if end.is_some() {
            return if overflow {
                Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "MCP input exceeds 256 KiB",
                ))
            } else {
                Ok(Some(line))
            };
        }
    }
}

fn write_rpc(output: &Arc<Mutex<io::Stdout>>, value: &Value) {
    if let Ok(mut out) = output.lock() {
        let _ = serde_json::to_writer(&mut *out, value);
        let _ = out.write_all(b"\n");
        let _ = out.flush();
    }
}

fn rpc_result(id: Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"result":result})
}
fn rpc_error(id: Value, code: i32, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}

fn reap_finished(workers: &mut Vec<thread::JoinHandle<()>>) {
    let mut index = 0;
    while index < workers.len() {
        if workers[index].is_finished() {
            let _ = workers.swap_remove(index).join();
        } else {
            index += 1;
        }
    }
}

fn mcp(registry: Registry) -> Result<(), String> {
    let output = Arc::new(Mutex::new(io::stdout()));
    let active: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>> = Arc::new(Mutex::new(HashMap::new()));
    let count = Arc::new(AtomicUsize::new(0));
    let input_fd = unsafe { libc::dup(0) };
    if input_fd < 0 {
        return Err("Cannot open MCP stdin".to_owned());
    }
    let flags = unsafe { libc::fcntl(input_fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(input_fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        unsafe {
            libc::close(input_fd);
        }
        return Err("Cannot configure MCP stdin".to_owned());
    }
    let input = unsafe { File::from_raw_fd(input_fd) };
    let mut reader = io::BufReader::new(input);
    let mut workers = Vec::new();
    loop {
        reap_finished(&mut workers);
        if INTERRUPTED.load(Ordering::SeqCst) {
            break;
        }
        if reader.buffer().is_empty() {
            let mut descriptor = libc::pollfd {
                fd: input_fd,
                events: libc::POLLIN,
                revents: 0,
            };
            unsafe {
                libc::poll(&mut descriptor, 1, 100);
            }
            if descriptor.revents == 0 {
                continue;
            }
        }
        let line = match read_line_limited(&mut reader, 256 * 1024, input_fd) {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => break,
            Err(error) => {
                write_rpc(&output, &rpc_error(Value::Null, -32700, &error.to_string()));
                continue;
            }
        };
        let message = match serde_json::from_slice::<Value>(&line) {
            Ok(message) => message,
            Err(error) => {
                write_rpc(
                    &output,
                    &rpc_error(Value::Null, -32700, &format!("Parse error: {error}")),
                );
                continue;
            }
        };
        if !message.is_object() || !message["method"].is_string() {
            write_rpc(
                &output,
                &rpc_error(
                    message.get("id").cloned().unwrap_or(Value::Null),
                    -32600,
                    "Invalid request",
                ),
            );
            continue;
        }
        let method = message["method"].as_str().unwrap_or("");
        if method == "notifications/cancelled" {
            let key = message["params"]["requestId"].to_string();
            if let Ok(map) = active.lock() {
                if let Some(cancel) = map.get(&key) {
                    cancel.store(true, Ordering::SeqCst);
                }
            }
            continue;
        }
        if message.get("id").is_none() {
            continue;
        }
        let id = message["id"].clone();
        let response = match method {
            "initialize" => Some(rpc_result(
                id,
                json!({"protocolVersion":"2025-03-26","capabilities":{"tools":{}},"serverInfo":{"name":"browser-task","version":env!("CARGO_PKG_VERSION")}}),
            )),
            "ping" => Some(rpc_result(id, json!({}))),
            "tools/list" => Some(rpc_result(
                id,
                json!({"tools":[{"name":"dev_browser","description":"Control a page owned by a managed browser task through typed actions","inputSchema":schema(),"annotations":{"readOnlyHint":false}}]}),
            )),
            "tools/call" => {
                if message["params"]["name"] != "dev_browser" {
                    Some(rpc_error(id, -32602, "Unknown tool"))
                } else if count.load(Ordering::SeqCst) >= 8 {
                    Some(rpc_error(id, -32000, "Browser task worker limit reached"))
                } else {
                    let request = serde_json::from_value::<ActionRequest>(
                        message["params"]["arguments"].clone(),
                    );
                    match request {
                        Err(error) => Some(rpc_error(
                            id,
                            -32602,
                            &format!("Invalid tool arguments: {error}"),
                        )),
                        Ok(request) => {
                            let key = id.to_string();
                            let cancel = Arc::new(AtomicBool::new(false));
                            let mut map =
                                active.lock().map_err(|_| "MCP worker registry poisoned")?;
                            if map.contains_key(&key) {
                                drop(map);
                                write_rpc(
                                    &output,
                                    &rpc_error(id, -32600, "Duplicate active request ID"),
                                );
                                continue;
                            }
                            count.fetch_add(1, Ordering::SeqCst);
                            map.insert(key.clone(), cancel.clone());
                            drop(map);
                            let registry = registry.clone();
                            let output = output.clone();
                            let active = active.clone();
                            let count = count.clone();
                            workers.push(thread::spawn(move||{
                                let result=execute(&registry,&request,&cancel);
                                let (text,is_error)=match result{Ok(value)=>(value.to_string(),false),Err(error)=>(error.chars().take(2048).collect(),true)};
                                write_rpc(&output,&rpc_result(id,json!({"content":[{"type":"text","text":text}],"isError":is_error})));
                                if let Ok(mut map)=active.lock(){map.remove(&key);}
                                count.fetch_sub(1,Ordering::SeqCst);
                            }));
                            None
                        }
                    }
                }
            }
            _ => Some(rpc_error(id, -32601, "Method not found")),
        };
        if let Some(response) = response {
            write_rpc(&output, &response);
        }
    }
    if let Ok(map) = active.lock() {
        for cancel in map.values() {
            cancel.store(true, Ordering::SeqCst);
        }
    }
    let shutdown = Instant::now() + Duration::from_secs(3);
    while workers.iter().any(|worker| !worker.is_finished()) && Instant::now() < shutdown {
        thread::sleep(Duration::from_millis(20));
    }
    for worker in workers {
        if worker.is_finished() {
            let _ = worker.join();
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completed_mcp_workers_do_not_accumulate() {
        let mut workers = Vec::new();
        for _ in 0..64 {
            workers.push(thread::spawn(|| {}));
            workers.last().unwrap().thread().unpark();
            while !workers.last().unwrap().is_finished() {
                thread::yield_now();
            }
            reap_finished(&mut workers);
            assert!(workers.is_empty());
        }
    }
}

fn main() {
    unsafe {
        libc::umask(0o077);
        libc::signal(libc::SIGINT, interrupt as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, interrupt as *const () as libc::sighandler_t);
    }
    let outcome = (|| {
        let options = parse_args()?;
        if options
            .positional
            .iter()
            .any(|argument| argument == "--help" || argument == "-h")
        {
            println!("browser-task [--config FILE] [--state-dir DIR] COMMAND\n\nCommands: start PROFILE --label LABEL [--url URL], open TASK [--page NAME] [--url URL], info TASK, list, keep TASK, resume TASK, finish TASK, cleanup, show [TASK] [--page NAME] [--profile PROFILE], action TASK [--page NAME] [--timeout SECONDS], schema, mcp\n\nThe action command reads one typed JSON action from stdin. Use schema to inspect accepted action types and fields. Timeout is 1..300 seconds.");
            return Ok::<(), String>(());
        }
        if options
            .positional
            .first()
            .is_some_and(|command| command == "schema")
        {
            println!("{}", schema());
            return Ok::<(), String>(());
        }
        let registry = registry(&options)?;
        if options
            .positional
            .first()
            .is_some_and(|command| command == "mcp")
        {
            mcp(registry)?;
        } else if let Some(result) = cli(&options, &registry)? {
            println!("{result}");
        }
        Ok(())
    })();
    if let Err(error) = outcome {
        eprintln!(
            "browser-task: {}",
            error.chars().take(2048).collect::<String>()
        );
        std::process::exit(1);
    }
}
