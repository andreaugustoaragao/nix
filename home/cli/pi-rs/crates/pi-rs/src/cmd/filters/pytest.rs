//! `pi-rs pytest` wrapper.
//!
//! Defaults to `-q` (quiet) to drop the per-test PASSED markers that
//! make pytest's default output verbose. The compress pipeline plus tee
//! handles the rest. Per-format JSON parsing via `pytest-json-report` is
//! a future smartness; failures still surface because `-q` keeps
//! `FAILED` / `ERROR` lines.

use clap::Args;

use super::{DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES, run_filtered};

#[derive(Args, Debug)]
pub struct PytestArgs {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub args: Vec<String>,
}

pub fn run(args: PytestArgs) -> anyhow::Result<()> {
    let has_quiet = args.args.iter().any(|a| a == "-q" || a == "--quiet" || a == "-v" || a == "--verbose");
    let mut argv: Vec<String> = Vec::with_capacity(args.args.len() + 1);
    if !has_quiet {
        argv.push("-q".into());
    }
    argv.extend(args.args);
    let refs: Vec<&str> = argv.iter().map(|s| s.as_str()).collect();
    let code = run_filtered("pytest", &refs, "pytest", DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES)?;
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}
