//! `pi-rs hash` — read a file (or stdin), emit hashline-anchored text.
//!
//! Output goes straight to stdout with no JSON wrapper because this is what
//! the model consumes verbatim: one anchored line per input line, in the
//! exact `LINE+HASH|TEXT` format used by omp's `read`/`search`/`edit`.

use std::{
    fs,
    io::{self, Read, Write},
    path::PathBuf,
};

use clap::Args as ClapArgs;

use crate::hashline::format_hash_lines;

#[derive(ClapArgs, Debug)]
pub struct Args {
    /// Path to read. Pass `-` (or omit) to read from stdin.
    #[arg(default_value = "-")]
    pub path: String,

    /// First line number (1-indexed). Used when displaying a slice that
    /// starts past the beginning of the source file.
    #[arg(long, default_value_t = 1)]
    pub start_line: u32,

    /// Read only lines [start..=end] (1-indexed, inclusive). If both are
    /// omitted, the entire input is hashed.
    #[arg(long)]
    pub start: Option<u32>,
    #[arg(long)]
    pub end: Option<u32>,
}

pub fn run(args: Args) -> anyhow::Result<()> {
    let text = if args.path == "-" {
        let mut s = String::new();
        io::stdin().read_to_string(&mut s)?;
        s
    } else {
        let p = PathBuf::from(&args.path);
        fs::read_to_string(&p)?
    };

    // Optional slice. If start/end given, take that 1-indexed inclusive
    // window. `start_line` for anchor numbering is the larger of the
    // explicit `--start-line` flag and the actual slice start.
    let (sliced, anchor_start) = match (args.start, args.end) {
        (None, None) => (text.as_str().to_string(), args.start_line),
        (Some(s), end) => {
            let lines: Vec<&str> = text.split('\n').collect();
            let start_idx = s.max(1).saturating_sub(1) as usize;
            let end_idx = end.map(|e| (e as usize).min(lines.len())).unwrap_or(lines.len());
            if start_idx >= lines.len() {
                (String::new(), s)
            } else {
                (lines[start_idx..end_idx].join("\n"), s)
            }
        }
        (None, Some(e)) => {
            let lines: Vec<&str> = text.split('\n').collect();
            let end_idx = (e as usize).min(lines.len());
            (lines[..end_idx].join("\n"), args.start_line)
        }
    };

    let out = format_hash_lines(&sliced, anchor_start);
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    handle.write_all(out.as_bytes())?;
    handle.write_all(b"\n")?;
    Ok(())
}
