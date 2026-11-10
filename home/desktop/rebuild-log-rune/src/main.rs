mod log;
mod state;
mod ui;

use state::{Inbox, State};
use std::{
    path::{Path, PathBuf},
    sync::mpsc,
    time::{Duration, SystemTime},
};

#[derive(PartialEq)]
struct Fingerprint {
    modified: Option<SystemTime>,
    len: u64,
    identity: (u64, u64),
}

fn fingerprint(path: &Path) -> Option<Fingerprint> {
    let metadata = path.metadata().ok()?;
    #[cfg(unix)]
    let identity = {
        use std::os::unix::fs::MetadataExt;
        (metadata.dev(), metadata.ino())
    };
    #[cfg(not(unix))]
    let identity = (0, 0);
    Some(Fingerprint {
        modified: metadata.modified().ok(),
        len: metadata.len(),
        identity,
    })
}

fn main() {
    rune::set_app_id("io.github.rebuild_log_rune");
    rune::prewarm_gpu();
    let state_dir = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state")
        })
        .join("noctalia-nix-rebuild");
    let mut log_path = state_dir.join("rebuild.log");
    let mut status_path = None;
    let mut rune_args = Vec::new();
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--log" || arg == "--status" {
            let Some(value) = args.next() else {
                eprintln!("{} requires a file path", arg.to_string_lossy());
                std::process::exit(2);
            };
            if arg == "--log" {
                log_path = value.into();
            } else {
                status_path = Some(PathBuf::from(value));
            }
        } else {
            match arg.into_string() {
                Ok(arg) => rune_args.push(arg),
                Err(_) => {
                    eprintln!("Rune options must be valid UTF-8; use --log for file paths.");
                    std::process::exit(2);
                }
            }
        }
    }
    let signature = (
        fingerprint(&log_path),
        status_path.as_deref().and_then(fingerprint),
    );
    let snapshot = log::Snapshot::load(&log_path, status_path.as_deref());
    let inbox = Inbox::default();
    let initial_inbox = inbox.clone();
    let app = rune::App::new(ui::spec())
        .args(rune_args)
        .init(move || State::new(snapshot, initial_inbox));
    let handle = app.handle();
    let (stop, stopped) = mpsc::channel::<()>();
    let worker = std::thread::spawn(move || {
        let mut previous = signature;
        while stopped.recv_timeout(Duration::from_millis(500))
            == Err(mpsc::RecvTimeoutError::Timeout)
        {
            let signature = (
                fingerprint(&log_path),
                status_path.as_deref().and_then(fingerprint),
            );
            if signature != previous {
                let snapshot = log::Snapshot::load(&log_path, status_path.as_deref());
                *inbox.lock().expect("log inbox") = Some(snapshot);
                handle.wake();
                previous = signature;
            }
        }
    });
    app.run();
    drop(stop);
    worker.join().expect("log watcher");
}

#[cfg(test)]
mod tests {
    use super::*;
    use rune::{Env, Runtime};

    #[test]
    fn native_controls_filter_and_copy_the_full_visible_log() {
        let snapshot = log::Snapshot::from_bytes(
            b"normal output\nwarning: dirty checkout\nerror: build failed\n",
        );
        let mut rt = rune::App::new(ui::spec())
            .init(move || State::new(snapshot, Inbox::default()))
            .headless_runtime((1160.0, 760.0), Env::new(true, 1.0));
        let clipboard = rune::clipboard::memory();
        rt.use_clipboard(&clipboard);
        rt.frame(0.0);
        let click = |rt: &mut Runtime<State>, key: &str| {
            let (x, y) = rt.find(key).unwrap();
            rt.pointer_down(x, y);
            rt.pointer_up(x, y);
            rt.frame(0.1);
        };
        click(&mut rt, "errors");
        assert_eq!(rt.state.visible, [2]);
        click(&mut rt, "copy");
        assert_eq!(clipboard.text().unwrap().as_str(), "error: build failed");
        click(&mut rt, "all");
        assert_eq!(rt.state.visible, [0, 1, 2]);
        rt.update(|_, tx| tx.select_text("message-2", 0..5));
        rt.frame(0.1);
        click(&mut rt, "copy");
        assert_eq!(clipboard.text().unwrap().as_str(), "error");
        click(&mut rt, "wrap");
        assert!(!rt.state.wrap);
    }

    #[test]
    fn virtual_rows_do_not_build_the_entire_history() {
        let bytes = "a log line\n".repeat(20_000);
        let snapshot = log::Snapshot::from_bytes(bytes.as_bytes());
        let mut rt = rune::App::new(ui::spec())
            .init(move || State::new(snapshot, Inbox::default()))
            .headless_runtime((800.0, 480.0), Env::new(true, 1.0));
        rt.frame(0.0);
        assert!(rt.elements().len() < 1000);
        assert_eq!(rt.state.log.lines.len(), 20_000);
    }
}
