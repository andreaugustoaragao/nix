//! `pi-rs npm` wrapper. See [`pnpm`](super::pnpm) and [`yarn`](super::yarn)
//! for the sibling package managers; all three share the same shape and
//! differ only in the binary spawned.

use clap::Args;

use super::{DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES, run_filtered};

#[derive(Args, Debug)]
pub struct NpmArgs {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub args: Vec<String>,
}

pub fn run(args: NpmArgs) -> anyhow::Result<()> {
    let refs: Vec<&str> = args.args.iter().map(|s| s.as_str()).collect();
    let hint = match args.args.first().map(String::as_str) {
        Some(sub) => format!("npm_{sub}"),
        None => "npm".into(),
    };
    let code = run_filtered("npm", &refs, &hint, DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES)?;
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}
