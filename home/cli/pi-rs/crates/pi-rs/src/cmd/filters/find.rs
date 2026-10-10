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
    /// Maximum matches in this page (default 1000).
    #[arg(long, default_value_t = 1000)]
    pub limit: usize,
    /// Global match offset, in sorted path order.
    #[arg(long, default_value_t = 0)]
    pub skip: usize,
}

pub fn run(args: FindArgs) -> anyhow::Result<()> {
    let matcher = globset::Glob::new(&args.pattern)
        .map_err(|e| anyhow::anyhow!("bad glob {:?}: {e}", args.pattern))?
        .compile_matcher();

    let mut matches: Vec<PathBuf> = Vec::new();
    for entry in WalkBuilder::new(&args.path).build() {
        let entry = entry?;
        if !entry.file_type().map(|t| t.is_file()).unwrap_or(false) {
            continue;
        }
        if let Some(name) = entry.file_name().to_str()
            && matcher.is_match(name)
        {
            matches.push(entry.path().to_path_buf());
        }
    }

    matches.sort();
    let total = matches.len();
    let matches: Vec<_> = matches
        .into_iter()
        .skip(args.skip)
        .take(args.limit)
        .collect();
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

    if args.skip + matches.len() < total {
        out.push_str(&format!(
            "[showing {} of {total}; continue with --skip {}]\n",
            matches.len(),
            args.skip + matches.len()
        ));
    }

    let r = truncate_with_tee(TruncateRequest {
        content: &out,
        original: None,
        head_lines: DEFAULT_HEAD_LINES * 2,
        tail_lines: DEFAULT_HEAD_LINES,

        tee_dir: None,
        max_bytes: None,
    })?;
    print!("{}", r.content);
    Ok(())
}
