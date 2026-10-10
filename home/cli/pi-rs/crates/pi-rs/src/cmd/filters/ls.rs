//! `pi-rs ls [PATH] [--all]` — compact directory listing.
//!
//! Walks the directory and emits a token-efficient listing. Files and
//! sub-directories are listed separately, with sub-directory entry counts
//! when known. Hidden entries (dotfiles) are omitted unless `--all`.

use std::path::PathBuf;

use clap::Args;

#[derive(Args, Debug)]
pub struct LsArgs {
    /// Directory to list (default: current working dir).
    #[arg(default_value = ".")]
    pub path: PathBuf,
    /// Include hidden entries (those starting with `.`).
    #[arg(short = 'a', long)]
    pub all: bool,
    /// Group files and directories and count each directory's entries.
    #[arg(long)]
    pub details: bool,
}

pub fn run(args: LsArgs) -> anyhow::Result<()> {
    let mut entries: Vec<std::fs::DirEntry> = std::fs::read_dir(&args.path)
        .map_err(|e| anyhow::anyhow!("ls {}: {e}", args.path.display()))?
        .collect::<Result<_, _>>()?;
    entries.sort_by_key(|e| e.file_name());

    let mut out = String::new();
    // Native one-name-per-line output is already compact. Avoid extra headers,
    // indentation and directory scans unless the caller asks for that detail.
    if !args.details {
        for entry in entries {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if args.all || !name.starts_with('.') {
                out.push_str(&format!("{name}\n"));
            }
        }
        return emit(&out);
    }

    let mut files: Vec<String> = Vec::new();
    let mut dirs: Vec<(String, Option<usize>)> = Vec::new();

    for entry in entries {
        let name = entry.file_name().to_string_lossy().to_string();
        if !args.all && name.starts_with('.') {
            continue;
        }
        match entry.file_type() {
            Ok(ft) if ft.is_dir() => {
                let count = std::fs::read_dir(entry.path())
                    .ok()
                    .map(|r| r.filter_map(|x| x.ok()).count());
                dirs.push((name, count));
            }
            _ => files.push(name),
        }
    }

    out.push_str(&format!("# {}\n", args.path.display()));
    if !dirs.is_empty() {
        out.push_str(&format!("dirs ({}):\n", dirs.len()));
        for (name, count) in &dirs {
            match count {
                Some(n) => out.push_str(&format!("  {name}/ ({n})\n")),
                None => out.push_str(&format!("  {name}/\n")),
            }
        }
    }
    if !files.is_empty() {
        out.push_str(&format!("files ({}):\n", files.len()));
        for name in &files {
            out.push_str(&format!("  {name}\n"));
        }
    }
    if dirs.is_empty() && files.is_empty() {
        out.push_str("(empty)\n");
    }
    emit(&out)
}

fn emit(out: &str) -> anyhow::Result<()> {
    use crate::compress::tee::{TruncateRequest, truncate_with_tee};
    let result = truncate_with_tee(TruncateRequest {
        content: out,
        original: None,
        head_lines: 2,
        tail_lines: 1,
        tee_dir: None,
        max_bytes: None,
    })?;
    print!("{}", result.content);
    Ok(())
}
