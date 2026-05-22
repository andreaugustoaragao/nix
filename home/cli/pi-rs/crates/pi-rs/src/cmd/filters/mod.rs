//! Per-tool wrappers: `pi-rs git`, `pi-rs cargo`, `pi-rs pytest`, etc.
//!
//! Each submodule subprocesses one external tool, applies the [`compress`]
//! primitives, and emits the result on stdout. Exit code propagates from
//! the underlying tool so the agent sees real success/failure signal.
//!
//! Wrappers are intentionally thin. The actual compression work happens in
//! [`crate::compress`]; per-tool smartness (arg defaulting, format hints)
//! lives in the wrapper. When upstream output format drifts, the wrapper
//! degrades gracefully because [`run_filtered`] always falls back to the
//! `truncate_with_tee` escape hatch.
//!
//! Derived from `rtk-ai/rtk@v0.40.0` (Apache-2.0). See workspace `NOTICE`.
//! Imported once and adapted to pi-rs's [`crate::compress`] primitives;
//! this tree evolves independently from upstream.

pub mod cargo;
pub mod docker;
pub mod find;
pub mod gh;
pub mod git;
pub mod json;
pub mod kubectl;
pub mod log;
pub mod ls;
pub mod npm;
pub mod pnpm;
pub mod pytest;
pub mod read;
pub mod yarn;

use std::process::{Command, Stdio};

use anyhow::{Context, Result};

use crate::compress::{
    dedupe::collapse_repeated,
    progress::strip_progress,
    tee::{TruncateRequest, truncate_with_tee},
};

/// Default head/tail budget for wrappers that don't override. Tuned so
/// most one-shot tool invocations fit without truncating; bigger outputs
/// roll over into the tee log.
pub const DEFAULT_HEAD_LINES: usize = 40;
pub const DEFAULT_TAIL_LINES: usize = 20;

/// Run a subprocess and emit the compressed output on stdout.
///
/// Captures stdout + stderr (combined), pipes through the compression
/// pipeline, prints the result, and returns the child exit code. Use this
/// from each wrapper's `run()` after any tool-specific arg massage.
///
/// Pipeline:
/// 1. [`strip_progress`] — drop progress bars, percent lines, throughput.
/// 2. [`collapse_repeated`] — fold runs of identical adjacent lines.
/// 3. [`truncate_with_tee`] — head + marker + tail if over budget; full
///    payload to `~/.local/share/pi-rs/tee/{ts}_{cmd_hint}.log`.
pub fn run_filtered(
    program: &str,
    args: &[&str],
    cmd_hint: &str,
    head: usize,
    tail: usize,
) -> Result<i32> {
    let output = Command::new(program)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .with_context(|| format!("failed to spawn `{program}`"))?;

    // Combine stdout + stderr in source order is impossible without ptys;
    // emit stdout first then stderr. Most tools concentrate the salient
    // signal on stdout so this is the right default.
    let mut combined = String::new();
    combined.push_str(&String::from_utf8_lossy(&output.stdout));
    if !output.stderr.is_empty() {
        if !combined.is_empty() && !combined.ends_with('\n') {
            combined.push('\n');
        }
        combined.push_str(&String::from_utf8_lossy(&output.stderr));
    }

    let stripped = strip_progress(&combined);
    let deduped = collapse_repeated(&stripped);
    let r = truncate_with_tee(TruncateRequest {
        content: &deduped,
        head_lines: head,
        tail_lines: tail,
        cmd_hint,
        tee_dir: None,
    })?;
    print!("{}", r.content);

    Ok(output.status.code().unwrap_or(1))
}

/// Convenience: run with the default budget.
pub fn run_filtered_default(program: &str, args: &[&str], cmd_hint: &str) -> Result<i32> {
    run_filtered(program, args, cmd_hint, DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES)
}
