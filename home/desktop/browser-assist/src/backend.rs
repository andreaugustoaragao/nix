use base64::Engine;
use rune::{Image, ImageCache};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Deserialize)]
pub struct Session {
    pub task: String,
    pub token: String,
    pub page: String,
    pub prompt: String,
}

#[derive(Clone, Deserialize)]
pub struct Control {
    pub reference: String,
    pub label: String,
    pub role: String,
    pub field: bool,
}

#[derive(Deserialize)]
pub struct Location {
    pub origin: String,
    pub url: String,
    pub title: String,
    pub width: f64,
    pub height: f64,
}

pub struct Frame {
    pub document: String,
    pub location: Location,
    pub controls: Vec<Control>,
    pub image: Image,
}

#[derive(Clone, Deserialize)]
pub struct Task {
    pub task: String,
    pub label: String,
    pub profile: String,
    pub state: String,
    pub pages: std::collections::BTreeMap<String, String>,
    pub assistance: Option<Value>,
}

pub enum Work {
    List,
    Begin { task: String, page: String },
    Frame,
    Act(Value),
    End(bool),
}

pub enum Outcome {
    Tasks(Vec<Task>),
    Frame {
        task: String,
        page: String,
        prompt: String,
        frame: Frame,
    },
    End,
}

pub struct Backend {
    pub command: String,
    pub args: Vec<String>,
}

impl Backend {
    fn run(&self, args: &[&str], input: Option<&Value>) -> Result<Value, String> {
        let mut child = Command::new(&self.command)
            .args(&self.args)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|_| {
                "Cannot start browser-task. Check that the desktop package is installed.".to_owned()
            })?;
        // Drain both pipes while waiting, including screenshots larger than a pipe buffer.
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let out = thread::spawn(move || {
            let mut bytes = Vec::new();
            stdout
                .take(24 * 1024 * 1024 + 1)
                .read_to_end(&mut bytes)
                .map(|_| bytes)
        });
        let err = thread::spawn(move || {
            let mut bytes = Vec::new();
            stderr.take(8192).read_to_end(&mut bytes).map(|_| bytes)
        });
        if let Some(input) = input {
            let mut pipe = child.stdin.take().unwrap();
            if serde_json::to_writer(&mut pipe, input)
                .and_then(|_| pipe.flush().map_err(serde_json::Error::io))
                .is_err()
            {
                let _ = child.kill();
                let _ = child.wait();
                let _ = out.join();
                let _ = err.join();
                return Err("Cannot send input to browser-task.".into());
            }
        } else {
            drop(child.stdin.take());
        }
        let deadline = Instant::now() + Duration::from_secs(35);
        let status = loop {
            if let Some(status) = child
                .try_wait()
                .map_err(|_| "Cannot check browser-task status")?
            {
                break status;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                let _ = out.join();
                let _ = err.join();
                return Err(
                    "The browser action timed out. Cancel assistance before recovering the task."
                        .into(),
                );
            }
            thread::sleep(Duration::from_millis(20));
        };
        let bytes = out
            .join()
            .map_err(|_| "Cannot read browser reply")?
            .map_err(|_| "Cannot read browser reply")?;
        let errors = err
            .join()
            .map_err(|_| "Cannot read browser status")?
            .map_err(|_| "Cannot read browser status")?;
        if !status.success() {
            return Err(String::from_utf8_lossy(&errors).trim().to_owned());
        }
        if bytes.len() > 24 * 1024 * 1024 {
            return Err("Browser reply exceeds the size limit.".into());
        }
        serde_json::from_slice(&bytes).map_err(|_| "Browser returned an invalid reply.".into())
    }

    fn action(&self, session: &Session, action: Value) -> Result<Value, String> {
        self.run(
            &["assist-action", &session.task],
            Some(&json!({"token":session.token,"action":action})),
        )
    }

    fn frame(&self, session: &Session, cache: &ImageCache) -> Result<Outcome, String> {
        #[derive(Deserialize)]
        struct WireFrame {
            document: String,
            location: Location,
            controls: Vec<Control>,
            png: String,
        }
        let wire: WireFrame =
            serde_json::from_value(self.action(session, json!({"type":"frame"}))?)
                .map_err(|_| "Invalid screenshot reply")?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(wire.png)
            .map_err(|_| "Invalid screenshot image")?;
        let image = cache.load(bytes);
        image
            .wait()
            .map_err(|_| "Cannot decode the browser screenshot")?;
        Ok(Outcome::Frame {
            task: session.task.clone(),
            page: session.page.clone(),
            prompt: session.prompt.clone(),
            frame: Frame {
                document: wire.document,
                location: wire.location,
                controls: wire.controls,
                image,
            },
        })
    }

    pub fn worker(
        self,
        mut session: Option<Session>,
        work: mpsc::Receiver<Work>,
        replies: mpsc::Sender<Result<Outcome, String>>,
    ) {
        let cache = ImageCache::new(std::sync::Arc::new(|| {}));
        while let Ok(work) = work.recv() {
            let outcome = (|| match work {
                Work::List => {
                    let tasks: Vec<Task> = self
                        .run(&["list"], None)?
                        .as_array()
                        .ok_or("Invalid task list")?
                        .iter()
                        .filter_map(|task| serde_json::from_value(task.clone()).ok())
                        .collect();
                    Ok(Outcome::Tasks(tasks))
                }
                Work::Begin { task, page } => {
                    if session.is_some() {
                        return Err("Return control before selecting another task.".into());
                    }
                    let handoff = self.run(&["assist-begin", &task, "--page", &page], None)?;
                    session = Some(Session {
                        task,
                        page,
                        token: handoff["token"]
                            .as_str()
                            .ok_or("Invalid assistance session")?
                            .into(),
                        prompt: handoff["prompt"].as_str().unwrap_or("").into(),
                    });
                    self.frame(session.as_ref().unwrap(), &cache)
                }
                Work::Frame => self.frame(
                    session.as_ref().ok_or("Select a browser task first.")?,
                    &cache,
                ),
                Work::Act(action) => {
                    let session = session.as_ref().ok_or("Select a browser task first.")?;
                    self.action(session, action)?;
                    // Let page handlers and redirects settle before showing the result.
                    thread::sleep(Duration::from_millis(150));
                    self.frame(session, &cache)
                }
                Work::End(resume) => {
                    if let Some(active) = &session {
                        self.run(
                            &[
                                "assist-end",
                                &active.task,
                                "--result",
                                if resume { "continue" } else { "cancel" },
                            ],
                            Some(&json!(active.token)),
                        )?;
                        session = None;
                    }
                    Ok(Outcome::End)
                }
            })();
            if replies.send(outcome).is_err() {
                break;
            }
        }
        // Closing the window never silently resumes automation.
        if let Some(active) = session {
            let _ = self.run(
                &["assist-end", &active.task, "--result", "cancel"],
                Some(&json!(active.token)),
            );
        }
    }
}
