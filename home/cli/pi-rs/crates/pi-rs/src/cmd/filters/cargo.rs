//! `pi-rs cargo` wrapper.
//!
//! Subprocesses `cargo` with the provided trailing args, then runs the
//! compress pipeline. Cargo emits a lot of progress noise on stderr
//! ("Compiling foo v0.1.0", "Finished `dev` profile..."), which
//! [`crate::compress::progress`] doesn't yet target by default — we rely
//! on the tee escape hatch for large builds. Per-format JSON parsing
//! (`--message-format=json`, NDJSON) is intentionally out of scope at this
//! tier; future smartness can layer on top.

use clap::Args;

use super::{DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES, run_filtered};

#[derive(Args, Debug)]
pub struct CargoArgs {
    /// Args passed verbatim to `cargo`.
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub args: Vec<String>,
}

pub fn run(args: CargoArgs) -> anyhow::Result<()> {
    let refs: Vec<&str> = args.args.iter().map(|s| s.as_str()).collect();
    let hint = match args.args.first().map(String::as_str) {
        Some(sub) => format!("cargo_{sub}"),
        None => "cargo".into(),
    };
    let code = run_filtered("cargo", &refs, &hint, DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES)?;
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}
