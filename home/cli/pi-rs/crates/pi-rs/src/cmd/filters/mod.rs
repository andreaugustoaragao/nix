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

use std::io::{IsTerminal, Read, Write};
use std::process::{Command, ExitStatus, Stdio};

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
///    payload to content-addressed plain/gzip files under `~/.local/share/pi-rs/tee/`.
pub fn run_filtered(
    program: &str,
    args: &[&str],
    _cmd_hint: &str,
    head: usize,
    tail: usize,
) -> Result<i32> {
    let kubectl_output = program == "kubectl"
        && args
            .iter()
            .any(|arg| arg.starts_with("-o") || arg.starts_with("--output"));
    if kubectl_output
        || args.iter().any(|arg| {
            matches!(*arg, "-z" | "--null" | "--null-data")
                || [
                    "--json",
                    "--format",
                    "--pretty",
                    "--porcelain",
                    "--message-format",
                ]
                .iter()
                .any(|flag| {
                    *arg == *flag || arg.strip_prefix(flag).is_some_and(|s| s.starts_with('='))
                })
        })
    {
        return run_passthrough(program, args);
    }
    if streaming_command(program, args) || std::io::stdin().is_terminal() {
        return run_passthrough(program, args);
    }
    // Sharing one pipe preserves the kernel's stdout/stderr write order. A PTY
    // is unnecessary and would change programs' colour/buffering behaviour.
    let (mut reader, writer) = std::io::pipe()?;
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::from(writer.try_clone()?))
        .stderr(Stdio::from(writer))
        .spawn()
        .with_context(|| format!("failed to spawn `{program}`"))?;
    let mut bytes = Vec::new();
    if let Err(error) = reader.read_to_end(&mut bytes) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error.into());
    }
    let status = child.wait()?;
    let Ok(combined) = std::str::from_utf8(&bytes) else {
        std::io::stdout().write_all(&bytes)?;
        return Ok(exit_code(status));
    };
    if combined.contains('\0') {
        std::io::stdout().write_all(&bytes)?;
        return Ok(exit_code(status));
    }

    let stripped = strip_progress(combined);
    let specific = match program {
        "cargo" => cargo::summarize(&stripped),
        "pytest"
            if !args
                .iter()
                .any(|a| a.starts_with("-v") || *a == "--verbose") =>
        {
            pytest::summarize(&stripped)
        }
        "git" => git::summarize(&stripped, args),
        "docker" | "kubectl" if args.contains(&"logs") => {
            crate::compress::dedupe::collapse_logs(&stripped)
        }
        _ => stripped,
    };
    let deduped = collapse_repeated(&specific);
    let r = truncate_with_tee(TruncateRequest {
        content: &deduped,
        original: Some(combined),
        head_lines: head,
        tail_lines: tail,

        tee_dir: None,
        max_bytes: None,
    })?;
    print!("{}", r.content);

    Ok(exit_code(status))
}

pub fn streaming_command(program: &str, args: &[&str]) -> bool {
    let has = |values: &[&str]| args.iter().any(|arg| values.contains(arg));
    let follow = has(&["-f", "--follow", "--follow=true"]);
    let watch = has(&["--watch", "--watch=true"]);
    match program {
        "docker" => {
            has(&["attach", "exec", "run", "events", "stats"]) || (has(&["logs"]) && follow)
        }
        "kubectl" => {
            has(&["attach", "exec", "port-forward", "proxy"])
                || watch
                || (has(&["logs"]) && follow)
                || (has(&["get"]) && has(&["-w", "--watch-only"]))
        }
        "cargo" => has(&["run", "watch", "--nocapture"]),
        "pytest" => has(&["--pdb", "--trace", "-s", "--capture=no"]),
        "npm" | "pnpm" | "yarn" => watch || has(&["dev", "start", "serve", "watch"]),
        _ => false,
    }
}

#[derive(clap::Args, Debug)]
pub struct ProxyArgs {
    #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
    pub command: Vec<String>,
}

pub fn proxy(args: ProxyArgs) -> Result<()> {
    let refs: Vec<&str> = args.command.iter().skip(1).map(String::as_str).collect();
    let code = run_passthrough(&args.command[0], &refs)?;
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}

/// Preserve streams and arguments exactly for formats intended for other tools.
pub fn run_passthrough(program: &str, args: &[&str]) -> Result<i32> {
    let status = Command::new(program)
        .args(args)
        .status()
        .with_context(|| format!("failed to spawn `{program}`"))?;
    Ok(exit_code(status))
}

fn exit_code(status: ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return 128 + signal;
        }
    }
    1
}
