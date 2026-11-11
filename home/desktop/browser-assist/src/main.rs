mod backend;
mod ui;

use backend::{Backend, Session, Work};
use std::{io::Read, sync::mpsc};

fn main() {
    let mut backend = Backend {
        command: std::env::var("BROWSER_TASK_BIN").unwrap_or_else(|_| "browser-task".into()),
        args: Vec::new(),
    };
    let mut request = false;
    let mut task = None;
    let mut page = "main".to_owned();
    let mut rune_args = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--request" => request = true,
            "--task" => task = args.next(),
            "--page" => page = args.next().expect("--page needs a name"),
            "--config" | "--state-dir" => {
                backend.args.push(arg);
                backend.args.push(args.next().expect("option needs a path"));
            }
            _ => rune_args.push(arg),
        }
    }
    let session: Option<Session> = if request {
        let mut bytes = Vec::new();
        std::io::stdin()
            .take(8192)
            .read_to_end(&mut bytes)
            .expect("assistance input");
        Some(serde_json::from_slice(&bytes).expect("invalid assistance session"))
    } else {
        None
    };
    let first = if session.is_some() {
        Work::Frame
    } else if let Some(task) = task {
        Work::Begin { task, page }
    } else {
        Work::List
    };
    let (send, work) = mpsc::channel();
    let (reply, receive) = mpsc::channel();
    let worker = std::thread::spawn(move || backend.worker(session, work, reply));
    send.send(first).expect("browser worker");
    // Deterministic captures wait for the first real browser frame, not a loading screen.
    let initial = if rune_args
        .iter()
        .any(|arg| arg == "--snap" || arg == "--tree")
    {
        receive
            .recv_timeout(std::time::Duration::from_secs(40))
            .ok()
    } else {
        None
    };
    rune::set_app_id("io.github.browser_assist");
    rune::App::new(ui::spec())
        .args(rune_args)
        .init(move || {
            let mut state = ui::State::connected(send, receive);
            state.initialize(initial);
            state
        })
        .run();
    let _ = worker.join();
}
