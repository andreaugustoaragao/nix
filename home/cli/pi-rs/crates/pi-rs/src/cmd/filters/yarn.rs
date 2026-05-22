//! `pi-rs yarn` wrapper.

use clap::Args;

use super::{DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES, run_filtered};

#[derive(Args, Debug)]
pub struct YarnArgs {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub args: Vec<String>,
}

pub fn run(args: YarnArgs) -> anyhow::Result<()> {
    let refs: Vec<&str> = args.args.iter().map(|s| s.as_str()).collect();
    let hint = match args.args.first().map(String::as_str) {
        Some(sub) => format!("yarn_{sub}"),
        None => "yarn".into(),
    };
    let code = run_filtered("yarn", &refs, &hint, DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES)?;
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}
