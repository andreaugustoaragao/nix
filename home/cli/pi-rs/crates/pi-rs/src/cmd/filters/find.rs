//! `pi-rs find PATTERN [PATH]` — compact find, results grouped by directory.
//!
//! Walks `PATH` (default current dir) honoring .gitignore, finds entries
//! whose name matches `PATTERN` (glob), and emits results grouped by
//! parent directory via [`crate::compress::group::group_by_directory`].
//! Tee fallback applies for huge result sets.

use std::path::PathBuf;

use clap::Args;
use ignore::WalkBuilder;

use super::DEFAULT_HEAD_LINES;
use crate::compress::group::group_by_directory;
use crate::compress::tee::{TruncateRequest, truncate_with_tee};

#[derive(Args, Debug)]
pub struct FindArgs {
    /// Filename glob (e.g. `*.rs`, `Cargo.toml`).
    pub pattern: String,
    /// Root directory (default: current working dir).
    #[arg(default_value = ".")]
    pub path: PathBuf,
    /// Cap matches before grouping (default 1000).
    #[arg(long, default_value_t = 1000)]
    pub limit: usize,
}

pub fn run(args: FindArgs) -> anyhow::Result<()> {
    let matcher = globset::Glob::new(&args.pattern)
        .map_err(|e| anyhow::anyhow!("bad glob {:?}: {e}", args.pattern))?
        .compile_matcher();

    let mut matches: Vec<PathBuf> = Vec::new();
    for entry in WalkBuilder::new(&args.path).build().filter_map(|r| r.ok()) {
        if matches.len() >= args.limit {
            break;
        }
        if !entry.file_type().map(|t| t.is_file()).unwrap_or(false) {
            continue;
        }
        if let Some(name) = entry.file_name().to_str()
            && matcher.is_match(name)
        {
            matches.push(entry.path().to_path_buf());
        }
    }

    let groups = group_by_directory(&matches);
    let mut out = String::new();
    out.push_str(&format!(
        "# {} matches for `{}` under {}\n",
        matches.len(),
        args.pattern,
        args.path.display()
    ));
    for (dir, names) in &groups {
        out.push_str(&format!("{}/ ({})\n", dir.display(), names.len()));
        for name in names {
            out.push_str("  ");
            out.push_str(&name.to_string_lossy());
            out.push('\n');
        }
    }

    let r = truncate_with_tee(TruncateRequest {
        content: &out,
        head_lines: DEFAULT_HEAD_LINES * 2,
        tail_lines: DEFAULT_HEAD_LINES,
        cmd_hint: "find",
        tee_dir: None,
    })?;
    print!("{}", r.content);
    Ok(())
}
