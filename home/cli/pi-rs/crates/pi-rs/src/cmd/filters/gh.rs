//! `pi-rs gh` — GitHub CLI wrapper.
//!
//! Passthrough subprocess with the standard compress pipeline. `gh pr
//! view`, `gh issue list`, and similar listing-style outputs benefit from
//! the tee escape hatch; per-format JSON parsing is out of scope at this
//! tier.

use clap::Args;

use super::{DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES, run_filtered};

#[derive(Args, Debug)]
pub struct GhArgs {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub args: Vec<String>,
}

pub fn run(args: GhArgs) -> anyhow::Result<()> {
    let refs: Vec<&str> = args.args.iter().map(|s| s.as_str()).collect();
    let hint = match args.args.first().map(String::as_str) {
        Some(sub) => format!("gh_{sub}"),
        None => "gh".into(),
    };
    let code = run_filtered("gh", &refs, &hint, DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES)?;
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}
