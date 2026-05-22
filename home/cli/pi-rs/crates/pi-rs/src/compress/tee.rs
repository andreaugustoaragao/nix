//! `truncate_with_tee`: head+tail truncation with full-output recovery.
//!
//! When a compressed payload would lose too much detail, the full raw output
//! is written to `~/.local/share/pi-rs/tee/{unix_ts}_{cmd}.log` and the
//! returned payload embeds a one-line marker pointing at the tee file. The
//! LLM can read the marker file directly if it needs the unfiltered output,
//! avoiding a re-run of the underlying command.
//!
//! Marker format (stable, do not change without coordinating prompts):
//!
//! ```text
//!   ... [N lines elided — full output: /path/to/tee.log]
//! ```

use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Truncation request: caller decides head/tail budgets and tee filename hint.
pub struct TruncateRequest<'a> {
    /// Raw content to truncate.
    pub content: &'a str,
    /// Lines kept from the start.
    pub head_lines: usize,
    /// Lines kept from the end.
    pub tail_lines: usize,
    /// Command name embedded in the tee filename. Non-`[A-Za-z0-9_-]` chars
    /// are replaced with `_`. Empty hint becomes `cmd`.
    pub cmd_hint: &'a str,
    /// Override the tee directory. Default: `dirs::data_local_dir()/pi-rs/tee/`.
    /// Useful for tests and for honoring a project-local override.
    pub tee_dir: Option<&'a Path>,
}

/// Truncation outcome.
#[derive(Debug)]
pub struct TruncateOutput {
    /// The compressed content (or the original, if it fit in budget).
    pub content: String,
    /// Path the full raw payload was written to. `Some` iff `truncated`.
    pub tee_path: Option<PathBuf>,
    /// True iff truncation actually happened.
    pub truncated: bool,
}

/// Stable elision marker recognized by the LLM. Single line, embedded in
/// the compressed output between head and tail blocks.
fn marker(elided: usize, tee_path: &Path) -> String {
    format!(
        "  ... [{elided} lines elided — full output: {}]",
        tee_path.display()
    )
}

/// Truncate `content` to a head/tail summary, writing the full payload to
/// disk when truncation is required.
pub fn truncate_with_tee(req: TruncateRequest<'_>) -> io::Result<TruncateOutput> {
    let lines: Vec<&str> = req.content.lines().collect();
    let total = lines.len();
    let budget = req.head_lines.saturating_add(req.tail_lines);

    // Under budget — passthrough, no tee.
    if total <= budget {
        return Ok(TruncateOutput {
            content: req.content.to_string(),
            tee_path: None,
            truncated: false,
        });
    }

    // Resolve tee directory, mkdir -p, write full content.
    let tee_dir = resolve_tee_dir(req.tee_dir)?;
    std::fs::create_dir_all(&tee_dir)?;
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let safe_cmd = sanitize_cmd(req.cmd_hint);
    let tee_path = tee_dir.join(format!("{ts}_{safe_cmd}.log"));
    std::fs::write(&tee_path, req.content)?;

    // Compose head + marker + tail.
    let elided = total - budget;
    let mut out = String::with_capacity(req.content.len() / 4);
    for line in &lines[..req.head_lines] {
        out.push_str(line);
        out.push('\n');
    }
    out.push_str(&marker(elided, &tee_path));
    out.push('\n');
    for line in &lines[total - req.tail_lines..] {
        out.push_str(line);
        out.push('\n');
    }

    Ok(TruncateOutput {
        content: out,
        tee_path: Some(tee_path),
        truncated: true,
    })
}

/// Resolve the tee directory.
///
/// Caller override wins. Otherwise: `dirs::data_local_dir()` (which honors
/// `XDG_DATA_HOME` then falls back to `~/.local/share/`), then
/// `/pi-rs/tee/`.
pub fn resolve_tee_dir(override_dir: Option<&Path>) -> io::Result<PathBuf> {
    if let Some(p) = override_dir {
        return Ok(p.to_path_buf());
    }
    let base = dirs::data_local_dir().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "no XDG_DATA_HOME and no HOME — cannot resolve pi-rs data dir",
        )
    })?;
    Ok(base.join("pi-rs").join("tee"))
}

/// Filename-safe form of a command hint. Anything outside `[A-Za-z0-9_-]`
/// is replaced with `_`. Empty input becomes `cmd`.
fn sanitize_cmd(s: &str) -> String {
    let s = s.trim();
    if s.is_empty() {
        return String::from("cmd");
    }
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn req<'a>(
        content: &'a str,
        head: usize,
        tail: usize,
        cmd: &'a str,
        dir: &'a Path,
    ) -> TruncateRequest<'a> {
        TruncateRequest {
            content,
            head_lines: head,
            tail_lines: tail,
            cmd_hint: cmd,
            tee_dir: Some(dir),
        }
    }

    #[test]
    fn passthrough_when_under_budget() {
        // 5 lines, budget 3+3=6. Should passthrough unchanged.
        let tmp = TempDir::new().unwrap();
        let content = "a\nb\nc\nd\ne\n";
        let out = truncate_with_tee(req(content, 3, 3, "test", tmp.path())).unwrap();
        assert!(!out.truncated);
        assert!(out.tee_path.is_none());
        assert_eq!(out.content, content);
    }

    #[test]
    fn passthrough_when_exactly_at_budget() {
        // Boundary: total == budget should still passthrough (no info lost).
        let tmp = TempDir::new().unwrap();
        let content = "a\nb\nc\nd\ne\nf\n";
        let out = truncate_with_tee(req(content, 3, 3, "test", tmp.path())).unwrap();
        assert!(!out.truncated);
    }

    #[test]
    fn truncates_when_over_budget() {
        // 10 lines, budget 2+2=4. Should produce head + marker + tail.
        let tmp = TempDir::new().unwrap();
        let content: String = (1..=10).map(|i| format!("line{i}\n")).collect();
        let out = truncate_with_tee(req(&content, 2, 2, "test", tmp.path())).unwrap();
        assert!(out.truncated);
        let tee = out.tee_path.expect("tee path on truncation");
        // Lines in compressed form: 2 head + 1 marker + 2 tail = 5.
        let n: usize = out.content.lines().count();
        assert_eq!(n, 5);
        // Head and tail preserved exactly.
        let lines: Vec<&str> = out.content.lines().collect();
        assert_eq!(lines[0], "line1");
        assert_eq!(lines[1], "line2");
        assert_eq!(lines[3], "line9");
        assert_eq!(lines[4], "line10");
        // Marker mentions elided count and tee path.
        assert!(lines[2].contains("6 lines elided"));
        assert!(lines[2].contains(tee.to_string_lossy().as_ref()));
        // Tee file holds the unmodified original content.
        let tee_content = std::fs::read_to_string(&tee).unwrap();
        assert_eq!(tee_content, content);
    }

    #[test]
    fn tee_filename_includes_sanitized_cmd_hint() {
        let tmp = TempDir::new().unwrap();
        let content: String = (1..=50).map(|i| format!("{i}\n")).collect();
        let out = truncate_with_tee(req(&content, 1, 1, "git diff/HEAD~1", tmp.path())).unwrap();
        let name = out
            .tee_path
            .as_ref()
            .unwrap()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .to_string();
        // Sanitized: spaces, slashes, tildes → underscores.
        assert!(name.contains("git_diff_HEAD_1"), "got name: {name}");
        // Suffix .log
        assert!(name.ends_with(".log"));
    }

    #[test]
    fn empty_cmd_hint_falls_back_to_cmd() {
        let tmp = TempDir::new().unwrap();
        let content: String = (1..=10).map(|i| format!("{i}\n")).collect();
        let out = truncate_with_tee(req(&content, 1, 1, "  ", tmp.path())).unwrap();
        let name = out
            .tee_path
            .unwrap()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .to_string();
        assert!(name.contains("_cmd."), "got: {name}");
    }

    #[test]
    fn override_dir_is_created_if_missing() {
        let tmp = TempDir::new().unwrap();
        let nested = tmp.path().join("a/b/c");
        let content: String = (1..=10).map(|i| format!("{i}\n")).collect();
        let out = truncate_with_tee(req(&content, 1, 1, "x", &nested)).unwrap();
        assert!(out.tee_path.unwrap().starts_with(&nested));
    }

    #[test]
    fn marker_format_is_stable() {
        // Regression guard: prompts and hooks rely on the literal marker
        // shape to detect truncation. Changing this requires updating every
        // downstream consumer.
        let tmp = TempDir::new().unwrap();
        let path = tmp.path().join("dummy.log");
        let m = marker(42, &path);
        assert!(m.starts_with("  ... ["));
        assert!(m.contains("42 lines elided"));
        assert!(m.contains("full output: "));
        assert!(m.ends_with(']'));
    }
}
