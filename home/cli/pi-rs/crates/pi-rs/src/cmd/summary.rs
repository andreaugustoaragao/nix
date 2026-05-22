//! `pi-rs summary` — tree-sitter elision summary of a source file.
//!
//! Delegates to `pi_ast::summary::summarize_code` (vendored from omp) and
//! renders the kept/elided segments into omp's "summary block" format:
//!
//! ```text
//! 1ab|use std::fs;
//! 2cd|
//! 3ef|pub fn open(...) -> Result<File> {
//! ...
//! 19gh|}
//! ```
//!
//! Elision spans collapse to a single `...` line. When an elision sits
//! between matching brace lines, head and tail merge so an opener/closer
//! pair becomes one anchored line — same trick omp uses to keep the
//! summarized text compact.

use std::{fs, path::PathBuf};

use clap::Args as ClapArgs;
use serde_json::json;

use crate::{hashline::compute_line_hash, proto};

#[derive(ClapArgs, Debug)]
pub struct Args {
    /// File to summarize.
    pub path: PathBuf,

    /// Language alias override (e.g. "rust", "typescript"). Inferred from
    /// path extension when omitted.
    #[arg(long)]
    pub lang: Option<String>,

    /// Minimum total node lines before eliding a body/literal node.
    /// Defaults to pi_ast's value (4).
    #[arg(long)]
    pub min_body_lines: Option<u32>,

    /// Minimum total comment lines before eliding a multiline block
    /// comment. Defaults to pi_ast's value (6).
    #[arg(long)]
    pub min_comment_lines: Option<u32>,

    /// When the source is too large to summarize, emit a `details.error`
    /// field instead of falling back to verbatim text. Default behavior is
    /// to dump the whole file as kept content.
    #[arg(long)]
    pub strict: bool,
}

pub fn run(args: Args) -> anyhow::Result<()> {
    let code = fs::read_to_string(&args.path)?;
    let path_str = args.path.to_string_lossy().into_owned();

    let result = pi_ast::summary::summarize_code(pi_ast::summary::SummaryOptions {
        code: code.clone(),
        lang: args.lang.clone(),
        path: Some(path_str.clone()),
        min_body_lines: args.min_body_lines,
        min_comment_lines: args.min_comment_lines,
    })?;

    if args.strict && !result.parsed {
        proto::emit(
            "[summary unavailable: parse failed or unsupported language]",
            json!({
                "path": path_str,
                "parsed": false,
                "language": result.language,
                "totalLines": result.total_lines,
            }),
        )?;
        return Ok(());
    }

    let rendered = render_summary(&path_str, &result);
    proto::emit(
        &rendered.content,
        json!({
            "path": path_str,
            "language": result.language,
            "parsed": result.parsed,
            "elided": result.elided,
            "totalLines": result.total_lines,
            "elidedSpans": rendered.elided_spans,
            "elidedLines": rendered.elided_lines,
        }),
    )
}

struct Rendered {
    content: String,
    elided_spans: u32,
    elided_lines: u32,
}

fn render_summary(path: &str, summary: &pi_ast::summary::SummaryResult) -> Rendered {
    // Each segment is either a `kept` run (verbatim text we'll anchor line by
    // line) or an `elided` span. We emit anchored kept lines and a single
    // `...` elision marker per elided segment, then attach a recovery
    // footer when at least one elision was emitted.

    let mut out = String::new();
    let mut elided_spans: u32 = 0;
    let mut elided_lines: u32 = 0;

    for segment in &summary.segments {
        match segment.kind.as_str() {
            "kept" => {
                if let Some(text) = &segment.text {
                    let mut n = segment.start_line;
                    for line in text.split('\n') {
                        out.push_str(&n.to_string());
                        out.push_str(compute_line_hash(line));
                        out.push('|');
                        out.push_str(line);
                        out.push('\n');
                        n += 1;
                    }
                }
            }
            "elided" => {
                elided_spans += 1;
                elided_lines += segment.end_line - segment.start_line + 1;
                out.push_str("...\n");
            }
            other => {
                // Forward-compat: unknown segment kinds become plain
                // commentary lines so the model still sees them.
                out.push_str(&format!("[{other}]\n"));
            }
        }
    }

    if elided_spans > 0 {
        out.push_str(&format!(
            "\n[{elided_lines} lines across {elided_spans} elided regions; read {path}:raw or a line range like {path}:1-9999 for verbatim content]\n"
        ));
    }

    Rendered {
        content: out,
        elided_spans,
        elided_lines,
    }
}
