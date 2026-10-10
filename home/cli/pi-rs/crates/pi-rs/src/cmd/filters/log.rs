//! `pi-rs log FILE` — deduplicated log viewer.
//!
//! Reads `FILE`, applies [`crate::compress::dedupe`] to fold runs of
//! identical adjacent lines, then [`truncate_with_tee`] for overall size
//! control. Designed for long log files where a few hot lines repeat
//! thousands of times.

use std::path::PathBuf;

use clap::Args;

use super::DEFAULT_HEAD_LINES;
use crate::compress::dedupe::collapse_logs;
use crate::compress::tee::{TruncateRequest, truncate_with_tee};

#[derive(Args, Debug)]
pub struct LogArgs {
    /// Path to the log file.
    pub path: PathBuf,
}

pub fn run(args: LogArgs) -> anyhow::Result<()> {
    let raw = std::fs::read_to_string(&args.path)
        .map_err(|e| anyhow::anyhow!("read {}: {e}", args.path.display()))?;
    let deduped = collapse_logs(&raw);
    let r = truncate_with_tee(TruncateRequest {
        content: &deduped,
        original: Some(&raw),
        head_lines: DEFAULT_HEAD_LINES * 2,
        tail_lines: DEFAULT_HEAD_LINES * 2,

        tee_dir: None,
        max_bytes: None,
    })?;
    print!("{}", r.content);
    Ok(())
}
