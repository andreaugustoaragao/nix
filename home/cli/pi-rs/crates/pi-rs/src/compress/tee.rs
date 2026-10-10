//! Output-size budgets with complete, content-addressed recovery.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use super::recovery::{self, Limits};

pub const DEFAULT_OUTPUT_BYTES: usize = 32_000;
static OUTPUT_BYTES: AtomicUsize = AtomicUsize::new(DEFAULT_OUTPUT_BYTES);

pub fn set_output_budget(bytes: usize) {
    OUTPUT_BYTES.store(bytes, Ordering::Relaxed);
}

pub fn output_budget() -> usize {
    OUTPUT_BYTES.load(Ordering::Relaxed)
}

pub struct TruncateRequest<'a> {
    pub content: &'a str,
    /// Unfiltered output. Recovery never substitutes an already filtered copy.
    pub original: Option<&'a str>,
    /// Relative head/tail weights, retained from the former line-budget API.
    pub head_lines: usize,
    pub tail_lines: usize,
    pub tee_dir: Option<&'a Path>,
    /// Override the configured output byte budget (primarily for targeted reads).
    pub max_bytes: Option<usize>,
}

#[derive(Debug)]
pub struct TruncateOutput {
    pub content: String,
    pub tee_path: Option<PathBuf>,
    pub truncated: bool,
}

fn marker(bytes: usize, path: &Path) -> String {
    format!(
        "  ... [{bytes} bytes elided — full output: {}]",
        path.display()
    )
}

fn head_boundary(text: &str, bytes: usize) -> usize {
    let mut end = bytes.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end]
        .rfind('\n')
        .filter(|n| *n > end / 2)
        .map_or(end, |n| n + 1)
}

fn tail_boundary(text: &str, bytes: usize) -> usize {
    let mut start = text.len().saturating_sub(bytes);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    text[start..]
        .find('\n')
        .filter(|n| *n < bytes / 2)
        .map_or(start, |n| start + n + 1)
}

fn render(req: &TruncateRequest<'_>, path: &Path, budget: usize) -> Option<String> {
    let hint = format!("[full output: {}]\n", path.display());
    if req.content.len() + hint.len() < budget {
        let separator = if req.content.ends_with('\n') {
            ""
        } else {
            "\n"
        };
        return Some(format!("{}{separator}{hint}", req.content));
    }
    // Reserve the largest possible byte-count marker before choosing UTF-8 cuts.
    let overhead = marker(req.content.len(), path).len() + 2;
    let available = budget.checked_sub(overhead)?;
    if available == 0 {
        return None;
    }
    let weights = req.head_lines.saturating_add(req.tail_lines).max(1);
    let head = available.saturating_mul(req.head_lines) / weights;
    let end = head_boundary(req.content, head);
    let start = tail_boundary(req.content, available.saturating_sub(head));
    if start < end {
        return None;
    }
    Some(format!(
        "{}\n{}\n{}",
        &req.content[..end],
        marker(start - end, path),
        &req.content[start..]
    ))
}

pub fn truncate_with_tee(req: TruncateRequest<'_>) -> io::Result<TruncateOutput> {
    let original = req.original.unwrap_or(req.content);
    let passthrough = || TruncateOutput {
        content: original.to_owned(),
        tee_path: None,
        truncated: false,
    };
    let budget = req.max_bytes.unwrap_or_else(output_budget);
    if (original == req.content && original.len() <= budget) || req.content.trim().is_empty() {
        return Ok(passthrough());
    }
    let Ok(directory) = resolve_tee_dir(req.tee_dir) else {
        return Ok(passthrough());
    };
    // Estimate the longest cache filename before any disk write. Even the
    // recovery hint must fit and leave the result smaller than the original.
    let placeholder = directory.join("000000000000000000000000.log.gz");
    let Some(preview) = render(&req, &placeholder, budget) else {
        return Ok(passthrough());
    };
    if preview.len() >= original.len() {
        return Ok(passthrough());
    }
    let Ok(path) = recovery::store(original.as_bytes(), &directory, Limits::from_env()) else {
        return Ok(passthrough());
    };
    let Some(content) = render(&req, &path, budget) else {
        return Ok(passthrough());
    };
    Ok(TruncateOutput {
        content,
        tee_path: Some(path),
        truncated: true,
    })
}

pub fn resolve_tee_dir(override_dir: Option<&Path>) -> io::Result<PathBuf> {
    if let Some(path) = override_dir {
        return Ok(path.to_path_buf());
    }
    dirs::data_local_dir()
        .map(|p| p.join("pi-rs/tee"))
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no user data directory"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req<'a>(text: &'a str, directory: &'a Path, bytes: usize) -> TruncateRequest<'a> {
        TruncateRequest {
            content: text,
            original: None,
            head_lines: 2,
            tail_lines: 1,
            tee_dir: Some(directory),
            max_bytes: Some(bytes),
        }
    }

    #[test]
    fn moderate_files_do_not_lose_content_because_they_have_many_lines() {
        let dir = tempfile::tempdir().unwrap();
        let text = "setting=enabled\n".repeat(500);
        let out = truncate_with_tee(req(&text, dir.path(), DEFAULT_OUTPUT_BYTES)).unwrap();
        assert_eq!(out.content, text);
        assert!(!out.truncated);
        assert!(out.tee_path.is_none());
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    }

    #[test]
    fn byte_budget_handles_long_unicode_lines_with_exact_recovery() {
        let dir = tempfile::tempdir().unwrap();
        let text = "λ🙂".repeat(4000);
        let out = truncate_with_tee(req(&text, dir.path(), 512)).unwrap();
        assert!(out.content.len() <= 512);
        assert!(out.content.contains("bytes elided"));
        assert_eq!(
            recovery::read(&out.tee_path.unwrap()).unwrap(),
            text.as_bytes()
        );
    }

    #[test]
    fn filtered_payload_recovers_raw_input_and_never_expands_small_output() {
        let dir = tempfile::tempdir().unwrap();
        let raw = "warning: repeated diagnostic\n".repeat(1000);
        let mut request = req("warning: repeated diagnostic (x1000)\n", dir.path(), 512);
        request.original = Some(&raw);
        let out = truncate_with_tee(request).unwrap();
        assert_eq!(
            recovery::read(&out.tee_path.unwrap()).unwrap(),
            raw.as_bytes()
        );
        let mut small = req("shorter", dir.path(), 512);
        small.original = Some("slightly longer");
        let out = truncate_with_tee(small).unwrap();
        assert_eq!(out.content, "slightly longer");
        assert!(out.tee_path.is_none());
    }

    #[test]
    fn empty_filter_or_unavailable_storage_returns_original() {
        let dir = tempfile::tempdir().unwrap();
        let blocked = dir.path().join("not-a-directory");
        std::fs::write(&blocked, "occupied").unwrap();
        let raw = "arbitrary diagnostic\n".repeat(1000);
        let mut request = req("summary", &blocked, 512);
        request.original = Some(&raw);
        assert_eq!(truncate_with_tee(request).unwrap().content, raw);
        let mut request = req("", dir.path(), 512);
        request.original = Some(&raw);
        assert_eq!(truncate_with_tee(request).unwrap().content, raw);
    }
}
