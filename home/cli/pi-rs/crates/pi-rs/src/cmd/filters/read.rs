//! `pi-rs read FILE [--level=...]` — smart file reader.
//!
//! Modes:
//!
//! - `raw` (default): read the file as-is, apply [`truncate_with_tee`]
//!   so huge files don't blow the context. Mirrors what `cat FILE` does
//!   under the rewrite hook.
//! - `signature`: emit just the file's symbol signatures via
//!   [`crate::cmd::summary`] (tree-sitter outline). Equivalent to
//!   `pi-rs summary FILE` for supported languages; falls back to raw +
//!   truncate for languages summary doesn't understand.
//! - `aggressive`: alias for `signature`.
//!
//! The mode names match rtk's `rtk read --level=...` so prompts that
//! reference one work on the other.

use std::fs;
use std::path::PathBuf;

use clap::{Args, ValueEnum};

use super::DEFAULT_HEAD_LINES;
use crate::compress::tee::{TruncateRequest, truncate_with_tee};

#[derive(ValueEnum, Clone, Debug, Default)]
pub enum Level {
    /// Full file, head+tail truncated with tee fallback.
    #[default]
    Raw,
    /// Symbol signatures only (tree-sitter outline).
    Signature,
    /// Alias for `signature`.
    Aggressive,
}

#[derive(Args, Debug)]
pub struct ReadArgs {
    /// Path to read.
    pub path: PathBuf,
    /// Compression level.
    #[arg(short, long, value_enum, default_value_t = Level::Raw)]
    pub level: Level,
}

pub fn run(args: ReadArgs) -> anyhow::Result<()> {
    match args.level {
        Level::Raw => raw(&args.path),
        Level::Signature | Level::Aggressive => signature(&args.path),
    }
}

fn raw(path: &std::path::Path) -> anyhow::Result<()> {
    let content = fs::read_to_string(path)
        .map_err(|e| anyhow::anyhow!("read {}: {e}", path.display()))?;
    let hint = path
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "read".into());
    // Bigger budget than the wrappers — file reads are often the
    // intentional `give me this file` flow.
    let r = truncate_with_tee(TruncateRequest {
        content: &content,
        head_lines: DEFAULT_HEAD_LINES * 5,
        tail_lines: DEFAULT_HEAD_LINES,
        cmd_hint: &hint,
        tee_dir: None,
    })?;
    print!("{}", r.content);
    Ok(())
}

fn signature(path: &std::path::Path) -> anyhow::Result<()> {
    // Delegate to `pi-rs summary FILE` which already produces the
    // tree-sitter outline. We re-enter our own crate's `cmd::summary::run`
    // rather than subprocessing so this stays cheap. Defaults match the
    // standalone `pi-rs summary` invocation.
    crate::cmd::summary::run(crate::cmd::summary::Args {
        path: path.into(),
        lang: None,
        min_body_lines: None,
        min_comment_lines: None,
        strict: false,
    })
}
