//! `pi-rs docker` wrapper.
//!
//! `docker logs` is the high-value case (often huge, often repetitive).
//! The compress pipeline already dedupes adjacent identical lines via
//! [`crate::compress::dedupe`], so verbose container logs collapse
//! automatically. Other subcommands (`ps`, `images`, `inspect`, etc.) pass
//! through with the standard truncate-with-tee budget.

use clap::Args;

use super::{DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES, run_filtered};

#[derive(Args, Debug)]
pub struct DockerArgs {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub args: Vec<String>,
}

pub fn run(args: DockerArgs) -> anyhow::Result<()> {
    let refs: Vec<&str> = args.args.iter().map(|s| s.as_str()).collect();
    let hint = match args.args.first().map(String::as_str) {
        Some(sub) => format!("docker_{sub}"),
        None => "docker".into(),
    };
    let code = run_filtered("docker", &refs, &hint, DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES)?;
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}
