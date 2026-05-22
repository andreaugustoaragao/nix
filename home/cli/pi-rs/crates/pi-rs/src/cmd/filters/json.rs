//! `pi-rs json [FILE] [--structure]` — JSON structure viewer.
//!
//! Default mode pretty-prints the document with truncation. `--structure`
//! strips scalar values, keeping only key names and types — useful for
//! understanding the shape of an API response or config file without
//! pulling the full payload into context.

use std::io::Read;
use std::path::PathBuf;

use clap::Args;
use serde_json::Value;

use super::DEFAULT_HEAD_LINES;
use crate::compress::tee::{TruncateRequest, truncate_with_tee};

#[derive(Args, Debug)]
pub struct JsonArgs {
    /// Path to JSON file. Stdin used when omitted.
    pub path: Option<PathBuf>,
    /// Emit structure only — keys + types, drop scalar values.
    #[arg(short, long)]
    pub structure: bool,
}

pub fn run(args: JsonArgs) -> anyhow::Result<()> {
    let raw = match &args.path {
        Some(p) => std::fs::read_to_string(p)
            .map_err(|e| anyhow::anyhow!("read {}: {e}", p.display()))?,
        None => {
            let mut s = String::new();
            std::io::stdin().read_to_string(&mut s)?;
            s
        }
    };
    let value: Value = serde_json::from_str(&raw)
        .map_err(|e| anyhow::anyhow!("parse json: {e}"))?;

    let rendered = if args.structure {
        let mut s = String::new();
        render_structure(&value, 0, &mut s);
        s
    } else {
        serde_json::to_string_pretty(&value)?
    };

    let hint = args
        .path
        .as_ref()
        .and_then(|p| p.file_name())
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "json".into());
    let r = truncate_with_tee(TruncateRequest {
        content: &rendered,
        head_lines: DEFAULT_HEAD_LINES * 3,
        tail_lines: DEFAULT_HEAD_LINES,
        cmd_hint: &hint,
        tee_dir: None,
    })?;
    print!("{}", r.content);
    Ok(())
}

/// Render a JSON value's structure (keys + types) without scalar values.
fn render_structure(v: &Value, depth: usize, out: &mut String) {
    let indent = "  ".repeat(depth);
    match v {
        Value::Null => out.push_str(&format!("{indent}null\n")),
        Value::Bool(_) => out.push_str(&format!("{indent}<bool>\n")),
        Value::Number(_) => out.push_str(&format!("{indent}<number>\n")),
        Value::String(_) => out.push_str(&format!("{indent}<string>\n")),
        Value::Array(items) => {
            out.push_str(&format!("{indent}[{}] array\n", items.len()));
            if let Some(first) = items.first() {
                render_structure(first, depth + 1, out);
            }
        }
        Value::Object(map) => {
            out.push_str(&format!("{indent}{{{}}} object\n", map.len()));
            for (k, child) in map {
                out.push_str(&format!("{indent}  {k}:\n"));
                render_structure(child, depth + 2, out);
            }
        }
    }
}
