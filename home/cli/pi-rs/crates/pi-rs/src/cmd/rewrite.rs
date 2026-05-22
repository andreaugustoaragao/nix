//! `pi-rs rewrite` subcommand.
//!
//! Agent-facing API: takes a shell command string, returns either the same
//! string (passthrough) or its `pi-rs ...` rewrite. The command is always
//! emitted on stdout so callers can pipe unconditionally. With `--check`,
//! the decision ("passthrough" or "rewrite") is also printed to stderr.
//!
//! Exit code is always 0 in normal operation. Tokenization errors and
//! unknown commands resolve to passthrough; only true argv-parsing errors
//! at the clap layer return non-zero.

use clap::Args;

use crate::rewrite::{Decision, config::Config, rewrite};

#[derive(Args, Debug)]
pub struct RewriteArgs {
    /// Echo the decision label ("passthrough" or "rewrite") to stderr.
    #[arg(long)]
    pub check: bool,

    /// Shell command string to inspect. Must be a single quoted argument.
    /// Use `--` to disambiguate when the command starts with a flag.
    #[arg(allow_hyphen_values = true)]
    pub command: String,
}

pub fn run(args: RewriteArgs) -> anyhow::Result<()> {
    let config = Config::load();
    let decision = rewrite(&args.command, &config);

    if args.check {
        eprintln!(
            "{}",
            match &decision {
                Decision::Passthrough => "passthrough",
                Decision::Rewrite(_) => "rewrite",
            }
        );
    }

    let line = match decision {
        Decision::Passthrough => args.command,
        Decision::Rewrite(s) => s,
    };
    println!("{line}");
    Ok(())
}
