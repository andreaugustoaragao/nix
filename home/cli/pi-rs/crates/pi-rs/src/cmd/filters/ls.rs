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
}

pub fn run(args: LsArgs) -> anyhow::Result<()> {
    let mut entries: Vec<std::fs::DirEntry> = std::fs::read_dir(&args.path)
        .map_err(|e| anyhow::anyhow!("ls {}: {e}", args.path.display()))?
        .filter_map(|r| r.ok())
        .collect();
    entries.sort_by_key(|e| e.file_name());

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

    println!("# {}", args.path.display());
    if !dirs.is_empty() {
        println!("dirs ({}):", dirs.len());
        for (name, count) in &dirs {
            match count {
                Some(n) => println!("  {name}/ ({n})"),
                None => println!("  {name}/"),
            }
        }
    }
    if !files.is_empty() {
        println!("files ({}):", files.len());
        for name in &files {
            println!("  {name}");
        }
    }
    if dirs.is_empty() && files.is_empty() {
        println!("(empty)");
    }
    Ok(())
}
