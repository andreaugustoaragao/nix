use std::borrow::Borrow;
use std::collections::{BTreeMap, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::ops::Deref;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::actions::{self, Action, RefRecord, Viewport};
use crate::cdp::{valid_token, Cdp};

const RETENTION: f64 = 3600.0;

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Profile {
    pub port: u16,
    #[serde(rename = "appId")]
    pub app_id: String,
    pub headless: bool,
}

impl Profile {
    pub fn require_window(&self) -> Result<(), String> {
        if self.headless {
            Err("This browser profile is headless; inspect it with a screenshot action".to_owned())
        } else {
            Ok(())
        }
    }
}

#[derive(Clone)]
pub struct Registry {
    pub root: PathBuf,
    pub profiles: BTreeMap<String, Profile>,
    connections: Arc<Mutex<VecDeque<(String, Cdp)>>>,
}

macro_rules! token_type {
    ($name:ident) => {
        #[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(String);
        impl $name {
            fn new(value: String) -> Result<Self, String> {
                if valid_token(&value) {
                    Ok(Self(value))
                } else {
                    Err(format!("Invalid {}", stringify!($name)))
                }
            }
        }
        impl Deref for $name {
            type Target = str;
            fn deref(&self) -> &str {
                &self.0
            }
        }
        impl Borrow<str> for $name {
            fn borrow(&self) -> &str {
                &self.0
            }
        }
        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str(&self.0)
            }
        }
    };
}

token_type!(PageName);
token_type!(TargetId);
token_type!(BrowserInstance);

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct TaskId(String);
impl TaskId {
    fn new(value: String) -> Result<Self, String> {
        if canonical_uuid(&value) {
            Ok(Self(value))
        } else {
            Err("Invalid task identifier".to_owned())
        }
    }
}
impl Deref for TaskId {
    type Target = str;
    fn deref(&self) -> &str {
        &self.0
    }
}
impl std::fmt::Display for TaskId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskState {
    Active,
    Kept,
    Finished,
}
impl TaskState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Kept => "kept",
            Self::Finished => "finished",
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Task {
    pub task: TaskId,
    pub profile: String,
    pub instance: BrowserInstance,
    pub label: String,
    pub state: TaskState,
    pub pages: BTreeMap<PageName, TargetId>,
    pub finished_at: Option<f64>,
    pub resume_after: Option<f64>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub viewports: BTreeMap<String, Viewport>,
}

#[derive(Serialize, Deserialize)]
struct Journal {
    kind: String,
    page: String,
    started_at: f64,
}

pub struct Guard {
    _lock: File,
    pub directory: PathBuf,
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

fn random_bytes<const N: usize>() -> Result<[u8; N], String> {
    let mut bytes = [0; N];
    File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|error| format!("Cannot obtain random bytes: {error}"))?;
    Ok(bytes)
}

fn uuid() -> Result<String, String> {
    let mut bytes = random_bytes::<16>()?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!("{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
}

fn canonical_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

fn save_json<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    let bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    let suffix = random_bytes::<8>()?;
    let temporary = path.with_extension(format!(
        "tmp-{}",
        suffix
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    ));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
            .map_err(|error| error.to_string())?;
        file.write_all(&bytes).map_err(|error| error.to_string())?;
        file.write_all(b"\n").map_err(|error| error.to_string())?;
        file.sync_all().map_err(|error| error.to_string())?;
        fs::rename(&temporary, path).map_err(|error| error.to_string())?;
        File::open(path.parent().ok_or("Missing task directory")?)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| error.to_string())?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn prune_artifacts(directory: &Path, newest: &Path) -> Result<(), String> {
    let mut old = fs::read_dir(directory)
        .map_err(|error| error.to_string())?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path != newest
                && path.file_name().is_some_and(|name| {
                    let name = name.to_string_lossy();
                    name.starts_with("screenshot-") && name.ends_with(".png")
                })
        })
        .collect::<Vec<_>>();
    old.sort_by_key(|path| {
        fs::metadata(path)
            .and_then(|metadata| metadata.modified())
            .ok()
    });
    for path in old.iter().take(old.len().saturating_sub(19)) {
        fs::remove_file(path).map_err(|error| error.to_string())?;
    }
    Ok(())
}

impl Registry {
    pub fn new(root: PathBuf, profiles: BTreeMap<String, Profile>) -> Result<Self, String> {
        if profiles.len() != 2
            || !profiles.contains_key("accounts")
            || !profiles.contains_key("development")
            || profiles
                .values()
                .any(|profile| profile.port == 0 || !valid_token(&profile.app_id))
            || profiles["accounts"].port == profiles["development"].port
        {
            return Err("Invalid managed browser configuration".to_owned());
        }
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&root)
            .map_err(|error| error.to_string())?;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
            .map_err(|error| error.to_string())?;
        Ok(Self {
            root,
            profiles,
            connections: Arc::new(Mutex::new(VecDeque::new())),
        })
    }

    fn directory(&self, id: &str) -> Result<PathBuf, String> {
        if !canonical_uuid(id) {
            return Err("Expected a task UUID returned by browser-task start".to_owned());
        }
        Ok(self.root.join(id))
    }

    pub fn lock(&self, id: &str, deadline: Instant, blocking: bool) -> Result<Guard, String> {
        self.lock_inner(id, deadline, blocking, None)
    }

    fn lock_cancellable(
        &self,
        id: &str,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> Result<Guard, String> {
        self.lock_inner(id, deadline, true, Some(cancel))
    }

    fn lock_inner(
        &self,
        id: &str,
        deadline: Instant,
        blocking: bool,
        cancel: Option<&AtomicBool>,
    ) -> Result<Guard, String> {
        let directory = self.directory(id)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(directory.join("lock"))
            .map_err(|_| format!("Task {id} does not exist or has already been cleaned up"))?;
        loop {
            if crate::INTERRUPTED.load(std::sync::atomic::Ordering::Relaxed)
                || cancel.is_some_and(|token| token.load(std::sync::atomic::Ordering::Relaxed))
            {
                return Err("Browser operation cancelled".to_owned());
            }
            let status = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            if status == 0 {
                return Ok(Guard {
                    _lock: file,
                    directory,
                });
            }
            if !blocking {
                return Err("Task is busy".to_owned());
            }
            if Instant::now() >= deadline {
                return Err("Timed out waiting for task lock".to_owned());
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    pub fn load(&self, guard: &Guard) -> Result<Task, String> {
        let path = guard.directory.join("task.json");
        let bytes = fs::read(path).map_err(|_| {
            format!(
                "Cannot read task {}; leaving its tabs untouched",
                guard.directory.display()
            )
        })?;
        if bytes.len() > 256 * 1024 {
            return Err("Task record is too large".to_owned());
        }
        let mut task: Task = serde_json::from_slice(&bytes)
            .map_err(|_| "Invalid task record; leaving its tabs untouched".to_owned())?;
        if task.task.0
            != guard
                .directory
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
            || !canonical_uuid(&task.task)
            || !self.profiles.contains_key(&task.profile)
            || !valid_token(&task.instance)
            || task
                .pages
                .iter()
                .any(|(name, target)| !valid_token(name) || !valid_token(target))
            || task
                .pages
                .values()
                .collect::<std::collections::HashSet<_>>()
                .len()
                != task.pages.len()
            || (task.state == TaskState::Finished) != task.finished_at.is_some()
            || [task.finished_at, task.resume_after]
                .into_iter()
                .flatten()
                .any(|value| !value.is_finite() || value < 0.0)
        {
            return Err("Invalid task record; leaving its tabs untouched".to_owned());
        }
        if guard.directory.join("journal.json").exists() && task.state == TaskState::Active {
            task.state = TaskState::Kept;
        }
        Ok(task)
    }

    pub fn save(&self, task: &Task) -> Result<(), String> {
        save_json(&self.directory(&task.task)?.join("task.json"), task)
    }

    pub fn view(&self, task: &Task) -> Value {
        let mut value = serde_json::to_value(task).unwrap_or_else(|_| json!({}));
        value["cleanup_at"] = task
            .finished_at
            .map(|time| json!(time + RETENTION))
            .unwrap_or(Value::Null);
        value
    }

    fn connect(&self, task: &Task, deadline: Instant) -> Result<Cdp, String> {
        let browser = Cdp::connect(self.profiles[&task.profile].port, deadline)?;
        if browser.instance != task.instance.0 {
            return Err("Browser restarted; start a new task. Existing tabs will not be adopted automatically".to_owned());
        }
        Ok(browser)
    }

    fn take_connection(&self, task: &Task, deadline: Instant) -> Result<Cdp, String> {
        let cached = {
            let mut cache = self
                .connections
                .lock()
                .map_err(|_| "Browser connection cache poisoned")?;
            cache
                .iter()
                .position(|(id, _)| id == &task.task.0)
                .and_then(|index| cache.remove(index))
                .map(|(_, browser)| browser)
        };
        if let Some(browser) = cached {
            if Cdp::current_instance(self.profiles[&task.profile].port, deadline)?
                == browser.instance
                && browser.instance == task.instance.0
            {
                return Ok(browser);
            }
            return Err("Browser restarted; start a new task. Existing tabs will not be adopted automatically".to_owned());
        }
        self.connect(task, deadline)
    }

    fn return_connection(&self, id: &str, browser: Cdp) {
        if let Ok(mut cache) = self.connections.lock() {
            if cache.len() >= 8 {
                cache.pop_front();
            }
            cache.push_back((id.to_owned(), browser));
        }
    }

    fn discard_connection(&self, id: &str) {
        if let Ok(mut cache) = self.connections.lock() {
            if let Some(index) = cache.iter().position(|(cached_id, _)| cached_id == id) {
                cache.remove(index);
            }
        }
    }

    fn recover_interrupted(&self, task: &Task, target: &str, action: &Action) {
        let deadline = Instant::now() + Duration::from_secs(2);
        let Ok(mut browser) = Cdp::connect(self.profiles[&task.profile].port, deadline) else {
            return;
        };
        if browser.instance != task.instance.0 {
            return;
        }
        let Ok(reply) = browser.recovery_call(
            "Target.attachToTarget",
            json!({"targetId":target,"flatten":true}),
            None,
            deadline,
        ) else {
            return;
        };
        let Some(session) = reply["sessionId"].as_str() else {
            return;
        };
        match action {
            Action::Evaluate { .. } => {
                let _ = browser.recovery_call(
                    "Runtime.terminateExecution",
                    json!({}),
                    Some(session),
                    deadline,
                );
            }
            Action::Navigate { .. } => {
                let _ =
                    browser.recovery_call("Page.stopLoading", json!({}), Some(session), deadline);
            }
            Action::Click { .. } | Action::Fill { .. } => {
                let _ = browser.recovery_call(
                    "Input.dispatchMouseEvent",
                    json!({"type":"mouseReleased","x":0,"y":0,"button":"left","clickCount":1}),
                    Some(session),
                    deadline,
                );
            }
            Action::Key { key } => {
                let base = key.split('+').next_back().unwrap_or(key);
                let _ = browser.recovery_call(
                    "Input.dispatchKeyEvent",
                    json!({"type":"keyUp","key":base}),
                    Some(session),
                    deadline,
                );
            }
            _ => {}
        }
    }

    fn pages(
        browser: &mut Cdp,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> Result<BTreeMap<String, Value>, String> {
        let reply = browser.pages(deadline, cancel)?;
        Ok(reply["targetInfos"]
            .as_array()
            .ok_or("Browser did not return targets")?
            .iter()
            .filter_map(|item| {
                if item["type"] == "page" {
                    item["targetId"]
                        .as_str()
                        .map(|id| (id.to_owned(), item.clone()))
                } else {
                    None
                }
            })
            .collect())
    }

    fn ensure_page(
        &self,
        task: &mut Task,
        browser: &mut Cdp,
        name: &str,
        url: Option<&str>,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> Result<String, String> {
        if !valid_token(name) {
            return Err(
                "Page names must contain 1–128 letters, digits, underscores, or hyphens".to_owned(),
            );
        }
        if let Some(url) = url {
            validate_url(url)?;
        }
        let current = Self::pages(browser, deadline, cancel)?;
        let target = if let Some(target) = task.pages.get(name) {
            if !current.contains_key(target.as_ref() as &str) {
                return Err(format!(
                    "Page {name} was closed; choose a new page name to create a replacement"
                ));
            }
            target.clone()
        } else {
            let reply = browser.call(
                "Target.createTarget",
                json!({"url":"about:blank","background":true,"focus":false}),
                None,
                deadline,
                cancel,
            )?;
            let target = reply["targetId"]
                .as_str()
                .ok_or("Browser did not create a target")?
                .to_owned();
            if !valid_token(&target) {
                return Err("Browser returned an invalid target identifier".to_owned());
            }
            task.pages.insert(
                PageName::new(name.to_owned())?,
                TargetId::new(target.clone())?,
            );
            self.save(task)?;
            TargetId::new(target)?
        };
        if let Some(url) = url {
            let directory = self.directory(&task.task)?;
            let refs_path = directory.join(format!("refs-{name}.json"));
            let mut refs = BTreeMap::new();
            save_json(&refs_path, &refs)?;
            save_json(
                &directory.join("journal.json"),
                &Journal {
                    kind: "navigate".to_owned(),
                    page: name.to_owned(),
                    started_at: now(),
                },
            )?;
            let navigation = (|| {
                let session = browser.attach(&target, deadline, cancel)?;
                let mut viewport = task.viewports.get(name).cloned();
                if let Some(current) = &viewport {
                    browser.call("Emulation.setDeviceMetricsOverride", json!({"width":current.width,"height":current.height,"deviceScaleFactor":1,"mobile":false}), Some(&session), deadline, cancel)?;
                }
                actions::execute(
                    browser,
                    &session,
                    &Action::Navigate {
                        url: url.to_owned(),
                    },
                    &mut refs,
                    &mut viewport,
                    deadline,
                    cancel,
                )?;
                Ok::<(), String>(())
            })();
            if let Err(error) = navigation {
                if browser.has_unanswered_command()
                    || cancel.load(std::sync::atomic::Ordering::Relaxed)
                    || crate::INTERRUPTED.load(std::sync::atomic::Ordering::Relaxed)
                    || Instant::now() >= deadline
                {
                    task.state = TaskState::Kept;
                    task.finished_at = None;
                    self.save(task)?;
                    self.recover_interrupted(
                        task,
                        &target,
                        &Action::Navigate {
                            url: url.to_owned(),
                        },
                    );
                } else {
                    fs::remove_file(directory.join("journal.json"))
                        .map_err(|cause| cause.to_string())?;
                }
                return Err(error);
            }
            fs::remove_file(directory.join("journal.json")).map_err(|error| error.to_string())?;
        }
        Ok(target.to_string())
    }

    pub fn start(
        &self,
        profile: &str,
        label: &str,
        url: Option<&str>,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> Result<Value, String> {
        if !self.profiles.contains_key(profile) {
            return Err("Choose accounts or development".to_owned());
        }
        if label.len() > 512 {
            return Err("Task label is too long".to_owned());
        }
        if let Some(url) = url {
            validate_url(url)?;
        }
        let browser = Cdp::connect(self.profiles[profile].port, deadline)?;
        let id = uuid()?;
        let directory = self.directory(&id)?;
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .map_err(|error| error.to_string())?;
        let _guard = self.lock(&id, deadline, true)?;
        let mut task = Task {
            task: TaskId::new(id)?,
            profile: profile.to_owned(),
            instance: BrowserInstance::new(browser.instance.clone())?,
            label: label.to_owned(),
            state: TaskState::Active,
            pages: BTreeMap::new(),
            finished_at: None,
            resume_after: None,
            viewports: BTreeMap::new(),
        };
        self.save(&task)?;
        self.ensure_page(&mut task, &mut { browser }, "main", url, deadline, cancel)
            .map_err(|error| {
                format!(
                    "{error}; task {} remains available for inspection",
                    task.task
                )
            })?;
        Ok(self.view(&task))
    }

    pub fn open(
        &self,
        id: &str,
        name: &str,
        url: Option<&str>,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> Result<Value, String> {
        let guard = self.lock(id, deadline, true)?;
        let mut task = self.load(&guard)?;
        require_active(&task)?;
        let mut browser = self.connect(&task, deadline)?;
        self.ensure_page(&mut task, &mut browser, name, url, deadline, cancel)?;
        Ok(self.view(&task))
    }

    pub fn info(&self, id: &str, deadline: Instant) -> Result<Value, String> {
        let guard = self.lock(id, deadline, true)?;
        Ok(self.view(&self.load(&guard)?))
    }

    pub fn list(&self) -> Value {
        let mut records = Vec::new();
        if let Ok(directories) = fs::read_dir(&self.root) {
            for entry in directories.flatten() {
                let id = entry.file_name().to_string_lossy().to_string();
                if !canonical_uuid(&id) || !entry.path().join("task.json").exists() {
                    continue;
                }
                match self.info(&id, Instant::now() + Duration::from_millis(200)) {
                    Ok(view) => records.push(view),
                    Err(error) => records.push(json!({"task":id,"error":error})),
                }
            }
        }
        Value::Array(records)
    }

    pub fn transition(
        &self,
        id: &str,
        change: &str,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> Result<Value, String> {
        let guard = self.lock(id, deadline, true)?;
        let mut task = self.load(&guard)?;
        match change {
            "keep" => {
                task.state = TaskState::Kept;
                task.finished_at = None;
            }
            "finish" => {
                if task.state == TaskState::Kept {
                    return Err(
                        "Task is kept for the user; explicitly resume it before finishing"
                            .to_owned(),
                    );
                }
                if task.state == TaskState::Active {
                    if task.resume_after.is_some_and(|until| now() < until) {
                        return Err("A previous command may still be running; wait for its timeout before finishing".to_owned());
                    }
                    task.state = TaskState::Finished;
                    task.finished_at = Some(now());
                }
            }
            "resume" => {
                if !guard.directory.join("journal.json").exists()
                    && task.resume_after.is_some_and(|until| now() < until)
                {
                    return Err("Interrupted script may still be running; wait for its timeout before resuming".to_owned());
                }
                let mut browser = self.connect(&task, deadline)?;
                let current = Self::pages(&mut browser, deadline, cancel)?;
                let journal_path = guard.directory.join("journal.json");
                if journal_path.exists() {
                    let journal: Journal = serde_json::from_slice(
                        &fs::read(&journal_path).map_err(|error| error.to_string())?,
                    )
                    .map_err(|error| error.to_string())?;
                    if matches!(journal.kind.as_str(), "click" | "fill" | "key")
                        && task
                            .pages
                            .get(journal.page.as_str())
                            .is_some_and(|target| current.contains_key(target.as_ref() as &str))
                    {
                        return Err("Interrupted input may still be running; close its page before resuming this task".to_owned());
                    }
                    if let Some(target) = task.pages.get(journal.page.as_str()) {
                        if current.contains_key(target.as_ref() as &str) {
                            let session = browser.attach(target, deadline, cancel)?;
                            if journal.kind == "evaluate" {
                                browser.call(
                                    "Runtime.terminateExecution",
                                    json!({}),
                                    Some(&session),
                                    deadline,
                                    cancel,
                                )?;
                            }
                            if journal.kind == "navigate" {
                                browser.call(
                                    "Page.stopLoading",
                                    json!({}),
                                    Some(&session),
                                    deadline,
                                    cancel,
                                )?;
                            }
                        }
                    }
                    fs::remove_file(journal_path).map_err(|error| error.to_string())?;
                }
                task.state = TaskState::Active;
                task.finished_at = None;
                task.resume_after = None;
                for page in task.pages.keys() {
                    let _ = fs::remove_file(guard.directory.join(format!("refs-{page}.json")));
                }
            }
            _ => return Err("Unknown task transition".to_owned()),
        }
        self.save(&task)?;
        if change != "resume" {
            self.discard_connection(id);
        }
        Ok(self.view(&task))
    }

    pub fn action(
        &self,
        id: &str,
        page: &str,
        action: &Action,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> Result<Value, String> {
        let guard = self.lock_cancellable(id, deadline, cancel)?;
        let mut task = self.load(&guard)?;
        require_active(&task)?;
        let target = task
            .pages
            .get(page)
            .ok_or("Page is not registered on this task")?
            .clone();
        let mut browser = self.take_connection(&task, deadline)?;
        if !Self::pages(&mut browser, deadline, cancel)?.contains_key(target.as_ref() as &str) {
            return Err(format!(
                "Page {page} was closed; choose a new page name to create a replacement"
            ));
        }
        let session = browser.attach(&target, deadline, cancel)?;
        if self.profiles[&task.profile].headless {
            browser.call(
                "Emulation.setFocusEmulationEnabled",
                json!({"enabled":true}),
                Some(&session),
                deadline,
                cancel,
            )?;
        }
        let refs_path = guard.directory.join(format!("refs-{page}.json"));
        let mut refs: BTreeMap<String, RefRecord> = if refs_path.exists() {
            serde_json::from_slice(&fs::read(&refs_path).map_err(|error| error.to_string())?)
                .map_err(|error| error.to_string())?
        } else {
            BTreeMap::new()
        };
        let mut viewport = task.viewports.get(page).cloned();
        if let Some(current) = &viewport {
            browser.call("Emulation.setDeviceMetricsOverride",json!({"width":current.width,"height":current.height,"deviceScaleFactor":1,"mobile":false}),Some(&session),deadline,cancel)?;
        }
        let kind = action.kind();
        if matches!(kind, "snapshot" | "navigate") {
            refs.clear();
            save_json(&refs_path, &refs)?;
        }
        save_json(
            &guard.directory.join("journal.json"),
            &Journal {
                kind: kind.to_owned(),
                page: page.to_owned(),
                started_at: now(),
            },
        )?;
        let output = actions::execute(
            &mut browser,
            &session,
            action,
            &mut refs,
            &mut viewport,
            deadline,
            cancel,
        );
        let detached = if output.is_ok() {
            browser
                .call(
                    "Target.detachFromTarget",
                    json!({"sessionId":session}),
                    None,
                    deadline,
                    cancel,
                )
                .is_ok()
        } else {
            false
        };
        match output {
            Ok(output) => {
                if let Some(viewport) = viewport {
                    task.viewports.insert(page.to_owned(), viewport);
                } else {
                    task.viewports.remove(page);
                }
                self.save(&task)?;
                save_json(&refs_path, &refs)?;
                let mut result = output.result;
                if let Some(png) = output.screenshot {
                    if png.len() > 16 * 1024 * 1024 {
                        return Err("Screenshot exceeds 16 MiB".to_owned());
                    }
                    let name = random_bytes::<16>()?
                        .iter()
                        .map(|byte| format!("{byte:02x}"))
                        .collect::<String>();
                    let path = guard.directory.join(format!("screenshot-{name}.png"));
                    let mut file = OpenOptions::new()
                        .create_new(true)
                        .write(true)
                        .mode(0o600)
                        .open(&path)
                        .map_err(|error| error.to_string())?;
                    file.write_all(&png)
                        .and_then(|_| file.sync_all())
                        .map_err(|error| error.to_string())?;
                    result["path"] = json!(path);
                    result["mime"] = json!("image/png");
                    result["bytes"] = json!(png.len());
                    prune_artifacts(&guard.directory, &path)?;
                }
                fs::remove_file(guard.directory.join("journal.json"))
                    .map_err(|error| error.to_string())?;
                if detached {
                    self.return_connection(id, browser);
                }
                Ok(result)
            }
            Err(error) => {
                if browser.has_unanswered_command()
                    || cancel.load(std::sync::atomic::Ordering::Relaxed)
                    || crate::INTERRUPTED.load(std::sync::atomic::Ordering::Relaxed)
                    || Instant::now() >= deadline
                {
                    task.state = TaskState::Kept;
                    task.finished_at = None;
                    self.save(&task)?;
                    self.recover_interrupted(&task, &target, action);
                } else {
                    fs::remove_file(guard.directory.join("journal.json"))
                        .map_err(|cause| cause.to_string())?;
                }
                Err(error)
            }
        }
    }

    pub fn cleanup(&self, deadline: Instant, cancel: &AtomicBool) -> Value {
        let mut report = json!({"closed":[],"stale":[],"retry":[],"busy":[]});
        let Ok(directories) = fs::read_dir(&self.root) else {
            return report;
        };
        for entry in directories.flatten() {
            let id = entry.file_name().to_string_lossy().to_string();
            if !canonical_uuid(&id) || !entry.path().join("task.json").exists() {
                continue;
            }
            let guard = match self.lock(&id, deadline, false) {
                Ok(guard) => guard,
                Err(_) => {
                    report["busy"].as_array_mut().unwrap().push(json!(id));
                    continue;
                }
            };
            let mut task = match self.load(&guard) {
                Ok(task) => task,
                Err(error) => {
                    report["retry"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!({"task":id,"error":error}));
                    continue;
                }
            };
            if task.state != TaskState::Finished
                || task.finished_at.is_none_or(|at| now() < at + RETENTION)
            {
                continue;
            }
            let result = (|| {
                let mut browser = Cdp::connect(self.profiles[&task.profile].port, deadline)?;
                if browser.instance != task.instance.0 {
                    report["stale"].as_array_mut().unwrap().push(json!(id));
                } else {
                    let current = Self::pages(&mut browser, deadline, cancel)?;
                    for (name, target) in task.pages.clone() {
                        if current.contains_key(target.as_ref() as &str) {
                            let reply = browser.call(
                                "Target.closeTarget",
                                json!({"targetId":target}),
                                None,
                                deadline,
                                cancel,
                            )?;
                            if reply["success"] != true {
                                return Err(format!("Could not close owned target {target}"));
                            }
                            report["closed"].as_array_mut().unwrap().push(json!(target));
                        }
                        task.pages.remove(&name);
                        self.save(&task)?;
                    }
                }
                fs::remove_dir_all(&guard.directory).map_err(|error| error.to_string())?;
                Ok::<(), String>(())
            })();
            if let Err(error) = result {
                report["retry"]
                    .as_array_mut()
                    .unwrap()
                    .push(json!({"task":id,"error":error}));
            }
        }
        report
    }

    pub fn show_owned(
        &self,
        id: &str,
        page: &str,
        deadline: Instant,
        cancel: &AtomicBool,
    ) -> Result<(String, String, String), String> {
        let guard = self.lock(id, deadline, true)?;
        let mut task = self.load(&guard)?;
        self.profiles[&task.profile].require_window()?;
        let target = task
            .pages
            .get(page)
            .ok_or("The requested task page is no longer open")?
            .clone();
        let mut browser = self.connect(&task, deadline)?;
        let pages = Self::pages(&mut browser, deadline, cancel)?;
        let info = pages
            .get(target.as_ref() as &str)
            .ok_or("The requested task page is no longer open")?;
        task.state = TaskState::Kept;
        task.finished_at = None;
        self.save(&task)?;
        self.discard_connection(id);
        browser.call(
            "Target.activateTarget",
            json!({"targetId":target}),
            None,
            deadline,
            cancel,
        )?;
        Ok((
            task.profile,
            info["title"].as_str().unwrap_or("").to_owned(),
            target.to_string(),
        ))
    }

    pub fn keep_matching_target(
        &self,
        profile: &str,
        instance: &str,
        target: &str,
        deadline: Instant,
    ) -> Result<(), String> {
        let entries = fs::read_dir(&self.root).map_err(|error| error.to_string())?;
        for entry in entries.flatten() {
            let id = entry.file_name().to_string_lossy().to_string();
            if !canonical_uuid(&id) {
                continue;
            }
            let path = entry.path().join("task.json");
            let Ok(bytes) = fs::read(path) else {
                continue;
            };
            if bytes.len() > 256 * 1024 {
                continue;
            }
            let Ok(candidate) = serde_json::from_slice::<Task>(&bytes) else {
                continue;
            };
            if candidate.profile != profile
                || candidate.instance.0 != instance
                || !candidate.pages.values().any(|owned| owned.0 == target)
            {
                continue;
            }
            let guard = self.lock(&id, deadline, true)?;
            let mut task = self.load(&guard)?;
            if task.profile == profile
                && task.instance.0 == instance
                && task.pages.values().any(|owned| owned.0 == target)
            {
                task.state = TaskState::Kept;
                task.finished_at = None;
                self.save(&task)?;
                self.discard_connection(&id);
            }
        }
        Ok(())
    }
}

fn require_active(task: &Task) -> Result<(), String> {
    if task.state != TaskState::Active {
        return Err(format!(
            "Task is {}; use browser-task resume before further automation",
            task.state.as_str()
        ));
    }
    if task.resume_after.is_some_and(|until| now() < until) {
        return Err(
            "A previous command may still be running; wait for its timeout before retrying"
                .to_owned(),
        );
    }
    Ok(())
}

pub fn validate_url(url: &str) -> Result<(), String> {
    if url == "about:blank" || url.starts_with("http://") || url.starts_with("https://") {
        Ok(())
    } else {
        Err("Task URLs must use http or https, or be about:blank".to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_registry() -> (Registry, PathBuf) {
        let root = std::env::temp_dir().join(format!("browser-task-rust-test-{}", uuid().unwrap()));
        let profiles = BTreeMap::from([
            (
                "accounts".to_owned(),
                Profile {
                    port: 9331,
                    app_id: "agent-browser-accounts".to_owned(),
                    headless: false,
                },
            ),
            (
                "development".to_owned(),
                Profile {
                    port: 9332,
                    app_id: "agent-browser-development".to_owned(),
                    headless: false,
                },
            ),
        ]);
        (Registry::new(root.clone(), profiles).unwrap(), root)
    }

    #[test]
    fn legacy_record_round_trips_without_new_fields() {
        let raw = json!({
            "task":"b549bb92-25e7-4e76-b781-9cc6d3910b70",
            "profile":"development",
            "instance":"fixture-instance",
            "label":"Legacy browser task",
            "state":"active",
            "pages":{"main":"fixture-target"},
            "finished_at":null,
            "resume_after":null
        });
        let task: Task = serde_json::from_value(raw.clone()).unwrap();
        assert_eq!(task.state, TaskState::Active);
        assert_eq!(serde_json::to_value(task).unwrap(), raw);
    }

    #[test]
    fn orphan_journal_keeps_active_record_after_old_deadline() {
        let (registry, root) = test_registry();
        let id = uuid().unwrap();
        fs::create_dir(root.join(&id)).unwrap();
        let guard = registry
            .lock(&id, Instant::now() + Duration::from_secs(1), true)
            .unwrap();
        let task = Task {
            task: TaskId::new(id).unwrap(),
            profile: "development".to_owned(),
            instance: BrowserInstance::new("fixture-instance".to_owned()).unwrap(),
            label: "Interrupted task".to_owned(),
            state: TaskState::Active,
            pages: BTreeMap::new(),
            finished_at: None,
            resume_after: Some(now() - 3600.0),
            viewports: BTreeMap::new(),
        };
        registry.save(&task).unwrap();
        save_json(
            &guard.directory.join("journal.json"),
            &Journal {
                kind: "evaluate".to_owned(),
                page: "main".to_owned(),
                started_at: now() - 3600.0,
            },
        )
        .unwrap();
        let loaded = registry.load(&guard).unwrap();
        assert_eq!(loaded.state, TaskState::Kept);
        assert!(require_active(&loaded).is_err());
        drop(guard);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn screenshot_retention_preserves_returned_path() {
        let (_, root) = test_registry();
        for index in 0..20 {
            fs::write(
                root.join(format!("screenshot-{:032x}.png", index + 1)),
                b"old",
            )
            .unwrap();
        }
        let newest = root.join("screenshot-00000000000000000000000000000000.png");
        fs::write(&newest, b"new").unwrap();
        prune_artifacts(&root, &newest).unwrap();
        assert_eq!(fs::read(&newest).unwrap(), b"new");
        assert_eq!(fs::read_dir(&root).unwrap().count(), 20);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn finished_timestamp_survives_persisted_round_trip_exactly() {
        let (registry, root) = test_registry();
        let id = uuid().unwrap();
        fs::create_dir(root.join(&id)).unwrap();
        let task = Task {
            task: TaskId::new(id.clone()).unwrap(),
            profile: "development".to_owned(),
            instance: BrowserInstance::new("fixture-instance".to_owned()).unwrap(),
            label: "Finished task".to_owned(),
            state: TaskState::Finished,
            pages: BTreeMap::new(),
            finished_at: Some(1793117612.8829427),
            resume_after: None,
            viewports: BTreeMap::new(),
        };
        registry.save(&task).unwrap();
        let guard = registry
            .lock(&id, Instant::now() + Duration::from_secs(1), true)
            .unwrap();
        let reloaded = registry.load(&guard).unwrap();
        assert_eq!(
            reloaded.finished_at.unwrap().to_bits(),
            task.finished_at.unwrap().to_bits()
        );
        drop(guard);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn showing_owned_target_waits_for_inflight_task_before_keep() {
        let (registry, root) = test_registry();
        let id = uuid().unwrap();
        fs::create_dir(root.join(&id)).unwrap();
        let task = Task {
            task: TaskId::new(id.clone()).unwrap(),
            profile: "development".to_owned(),
            instance: BrowserInstance::new("fixture-instance".to_owned()).unwrap(),
            label: "Busy task".to_owned(),
            state: TaskState::Active,
            pages: BTreeMap::from([(
                PageName::new("main".to_owned()).unwrap(),
                TargetId::new("fixture-target".to_owned()).unwrap(),
            )]),
            finished_at: None,
            resume_after: None,
            viewports: BTreeMap::new(),
        };
        registry.save(&task).unwrap();
        let guard = registry
            .lock(&id, Instant::now() + Duration::from_secs(1), true)
            .unwrap();
        let other = registry.clone();
        let handle = thread::spawn(move || {
            other.keep_matching_target(
                "development",
                "fixture-instance",
                "fixture-target",
                Instant::now() + Duration::from_secs(2),
            )
        });
        thread::sleep(Duration::from_millis(50));
        assert!(!handle.is_finished());
        drop(guard);
        handle.join().unwrap().unwrap();
        let guard = registry
            .lock(&id, Instant::now() + Duration::from_secs(1), true)
            .unwrap();
        assert_eq!(registry.load(&guard).unwrap().state, TaskState::Kept);
        drop(guard);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn showing_headless_task_preserves_state_and_deadline() {
        let (mut registry, root) = test_registry();
        registry.profiles.get_mut("development").unwrap().headless = true;
        for (state, finished_at) in [
            (TaskState::Active, None),
            (TaskState::Kept, None),
            (TaskState::Finished, Some(1793117612.8829427)),
        ] {
            let id = uuid().unwrap();
            fs::create_dir(root.join(&id)).unwrap();
            let task = Task {
                task: TaskId::new(id.clone()).unwrap(),
                profile: "development".to_owned(),
                instance: BrowserInstance::new("fixture-instance".to_owned()).unwrap(),
                label: "Headless task".to_owned(),
                state,
                pages: BTreeMap::from([(
                    PageName::new("main".to_owned()).unwrap(),
                    TargetId::new("fixture-target".to_owned()).unwrap(),
                )]),
                finished_at,
                resume_after: None,
                viewports: BTreeMap::new(),
            };
            registry.save(&task).unwrap();
            let record = root.join(&id).join("task.json");
            let before = fs::read(&record).unwrap();
            let error = registry
                .show_owned(
                    &id,
                    "main",
                    Instant::now() + Duration::from_secs(1),
                    &AtomicBool::new(false),
                )
                .unwrap_err();
            assert!(error.contains("screenshot action"), "{error}");
            assert_eq!(fs::read(&record).unwrap(), before);
        }
        fs::remove_dir_all(root).unwrap();
    }
}
