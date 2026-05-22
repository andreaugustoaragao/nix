//! `pi-rs kubectl` wrapper.
//!
//! Shape mirrors [`super::docker`]: passthrough subprocess + standard
//! compress pipeline. The dedupe step is particularly valuable for
//! `kubectl logs` against busy pods.

use clap::Args;

use super::{DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES, run_filtered};

#[derive(Args, Debug)]
pub struct KubectlArgs {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub args: Vec<String>,
}

pub fn run(args: KubectlArgs) -> anyhow::Result<()> {
    let refs: Vec<&str> = args.args.iter().map(|s| s.as_str()).collect();
    let hint = match args.args.first().map(String::as_str) {
        Some(sub) => format!("kubectl_{sub}"),
        None => "kubectl".into(),
    };
    let code = run_filtered("kubectl", &refs, &hint, DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES)?;
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}
