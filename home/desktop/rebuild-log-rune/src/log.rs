use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::Path,
};

use chrono::{DateTime, FixedOffset};

const MAX_BYTES: u64 = 16 * 1024 * 1024;
const MAX_LINES: usize = 100_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Info,
    Warning,
    Error,
}

pub struct Line {
    pub text: String,
    pub timestamp: Option<DateTime<FixedOffset>>,
    pub level: Level,
    pub key: String,
}

impl Line {
    pub fn copy_text(&self) -> String {
        match self.timestamp {
            Some(timestamp) => format!(
                "[{}] {}",
                timestamp.format("%d %b %Y, %H:%M:%S UTC%:z"),
                self.text
            ),
            None => self.text.clone(),
        }
    }
}

#[derive(Default)]
pub struct Snapshot {
    pub lines: Vec<Line>,
    pub phase: String,
    pub message: String,
    pub truncated: bool,
    pub error: Option<String>,
}

pub fn level(text: &str) -> Level {
    let message = text.split_once("> ").map_or(text, |(_, message)| message);
    let message = message.trim_start().to_ascii_lowercase();
    if ["error:", "error[", "error ", "failed ", "fatal:", "panic:"]
        .iter()
        .any(|prefix| message.starts_with(prefix))
    {
        Level::Error
    } else if ["warning:", "warning[", "warn:"]
        .iter()
        .any(|prefix| message.starts_with(prefix))
    {
        Level::Warning
    } else {
        Level::Info
    }
}

impl Snapshot {
    pub fn from_bytes(bytes: &[u8]) -> Self {
        // The ANSI stripper discards CR. Resolve progress replacement first,
        // while treating CRLF as a newline rather than an empty replacement.
        let mut progress = Vec::with_capacity(bytes.len());
        for record in bytes.split_inclusive(|byte| *byte == b'\n') {
            let line = record.strip_suffix(b"\n").unwrap_or(record);
            let line = line.strip_suffix(b"\r").unwrap_or(line);
            progress.extend_from_slice(
                line.rsplit(|byte| *byte == b'\r')
                    .next()
                    .unwrap_or_default(),
            );
            if record.ends_with(b"\n") {
                progress.push(b'\n');
            }
        }
        let plain = strip_ansi_escapes::strip(progress);
        let text = String::from_utf8_lossy(&plain);
        let mut tail: Vec<_> = text.lines().rev().take(MAX_LINES + 1).collect();
        let truncated = tail.len() > MAX_LINES;
        tail.truncate(MAX_LINES);
        tail.reverse();
        let lines = tail
            .into_iter()
            .enumerate()
            .map(|(i, line)| {
                let (timestamp, message) = line
                    .strip_prefix('[')
                    .and_then(|line| line.split_once("] "))
                    .and_then(|(stamp, message)| {
                        DateTime::parse_from_rfc3339(stamp)
                            .ok()
                            .map(|stamp| (Some(stamp), message))
                    })
                    .unwrap_or((None, line));
                let text: String = message
                    .chars()
                    .filter(|c| !c.is_control() || *c == '\t')
                    .collect();
                Line {
                    level: level(&text),
                    text,
                    timestamp,
                    key: format!("line-{i}"),
                }
            })
            .collect();
        Self {
            lines,
            truncated,
            ..Self::default()
        }
    }

    pub fn load(log: &Path, status: Option<&Path>) -> Self {
        let mut snapshot = match read_tail(log) {
            Ok((bytes, truncated)) => {
                let mut snapshot = Self::from_bytes(&bytes);
                snapshot.truncated |= truncated;
                snapshot
            }
            Err(error) => Self {
                error: Some(format!("Cannot read {}: {error}", log.display())),
                ..Self::default()
            },
        };
        if let Some(status) = status {
            match std::fs::read(status).and_then(|bytes| {
                serde_json::from_slice::<serde_json::Value>(&bytes).map_err(std::io::Error::other)
            }) {
                Ok(value) => {
                    snapshot.phase = value["phase"].as_str().unwrap_or_default().into();
                    snapshot.message = value["message"].as_str().unwrap_or_default().into();
                }
                Err(_) => {
                    snapshot.message =
                        "Rebuild status unavailable; the log is still readable.".into()
                }
            }
        }
        snapshot
    }
}

fn read_tail(path: &Path) -> std::io::Result<(Vec<u8>, bool)> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    let start = len.saturating_sub(MAX_BYTES);
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::new();
    file.take(MAX_BYTES).read_to_end(&mut bytes)?;
    if start > 0 {
        // Drop the partial first line, rather than render a fragment as a full line.
        let cut = bytes
            .iter()
            .position(|b| *b == b'\n')
            .map_or(bytes.len(), |i| i + 1);
        bytes.drain(..cut);
    }
    Ok((bytes, start > 0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_terminal_sequences_and_preserves_unicode() {
        let log = Snapshot::from_bytes(b"\x1b[31merror: caf\xc3\xa9\x1b[0m\n\x1b]8;;https://example.invalid\x07link\x1b]8;;\x07\nold\rnew\n");
        assert_eq!(log.lines[0].text, "error: café");
        assert_eq!(log.lines[0].level, Level::Error);
        assert_eq!(log.lines[1].text, "link");
        assert_eq!(log.lines[2].text, "new");
        assert_eq!(level("warnings.nix"), Level::Info);
        assert_eq!(
            level("man-cache> Processing /nix/store/path/error.3"),
            Level::Info
        );
        assert_eq!(
            level("compiler> error[E0308]: mismatched types"),
            Level::Error
        );
        assert_eq!(level("warning: dirty checkout"), Level::Warning);
    }

    #[test]
    fn capture_times_are_readable_and_old_messages_keep_unknown_times() {
        let log = Snapshot::from_bytes(b"[2026-11-09T17:08:09-07:00] warning: example\nolder message\n[not a timestamp] literal message\n");
        assert_eq!(log.lines[0].level, Level::Warning);
        assert_eq!(log.lines[0].text, "warning: example");
        assert_eq!(
            log.lines[0]
                .timestamp
                .unwrap()
                .format("%d %b %H:%M:%S")
                .to_string(),
            "09 Nov 17:08:09"
        );
        assert_eq!(
            log.lines[0].copy_text(),
            "[09 Nov 2026, 17:08:09 UTC-07:00] warning: example"
        );
        assert!(log.lines[1].timestamp.is_none());
        assert!(log.lines[2].timestamp.is_none());
        assert_eq!(log.lines[2].text, "[not a timestamp] literal message");
    }

    #[test]
    fn rereads_appends_truncation_and_replaced_files() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("log with spaces; no shell");
        std::fs::write(&path, "first\n").unwrap();
        assert_eq!(Snapshot::load(&path, None).lines.len(), 1);
        std::fs::write(&path, "first\nsecond\n").unwrap();
        assert_eq!(Snapshot::load(&path, None).lines.len(), 2);
        std::fs::write(&path, "next\n").unwrap();
        assert_eq!(Snapshot::load(&path, None).lines[0].text, "next");
        let replacement = temp.path().join("replacement");
        std::fs::write(&replacement, "other\n").unwrap();
        std::fs::rename(replacement, &path).unwrap();
        assert_eq!(Snapshot::load(&path, None).lines[0].text, "other");
    }

    #[test]
    fn missing_logs_and_invalid_status_are_explicit() {
        let temp = tempfile::tempdir().unwrap();
        let log = temp.path().join("log");
        let status = temp.path().join("status.json");
        assert!(Snapshot::load(&log, None).error.is_some());
        std::fs::write(&log, "readable\n").unwrap();
        std::fs::write(&status, "not json").unwrap();
        let snapshot = Snapshot::load(&log, Some(&status));
        assert_eq!(snapshot.lines.len(), 1);
        assert!(snapshot.message.contains("unavailable"));
    }

    #[test]
    fn very_large_logs_have_bounded_history() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("large.log");
        let mut file = File::create(&path).unwrap();
        file.set_len(MAX_BYTES + 1024).unwrap();
        file.seek(SeekFrom::End(-8)).unwrap();
        use std::io::Write;
        file.write_all(b"\nlatest\n").unwrap();
        let snapshot = Snapshot::load(&path, None);
        assert!(snapshot.truncated);
        assert_eq!(snapshot.lines[0].text, "latest");
    }
}
