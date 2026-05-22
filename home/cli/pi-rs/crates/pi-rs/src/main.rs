//! `pi-rs` — single-binary toolbox of high-performance, context-aware
//! primitives invoked by pi-coding-agent extensions.
//!
//! Each subcommand maps to one tool the LLM is allowed to call. Stdout is the
//! tool's payload. Convention:
//!
//! - Subcommands that produce *text the model consumes* (`hash`, `html2md`)
//!   emit raw text on stdout — no JSON envelope, no field names, no quotes.
//! - Subcommands that produce *structured results* (`grep`, `summary`,
//!   `ast-grep`, `ast-edit`) emit one JSON object:
//!   `{"content": "<model-facing text>", "details": {...}}`.
//!   The TS extension passes `content` to the model and uses `details` to
//!   populate the tool result's `details` field for TUI rendering. The model
//!   never sees the JSON envelope.

use clap::{Parser, Subcommand};

mod cmd;
mod hashline;
mod proto;

#[derive(Parser, Debug)]
#[command(
    name = "pi-rs",
    version,
    about = "High-performance primitives for pi-coding-agent extensions",
    long_about = None,
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Format text with LINE+HASH|TEXT anchors compatible with omp hashline.
    Hash(cmd::hash::Args),
    /// Regex search across files / directories with grouped hashline output.
    Grep(cmd::grep::Args),
    /// Tree-sitter elision summary of a source file.
    Summary(cmd::summary::Args),
    /// Convert HTML on stdin to Markdown on stdout.
    Html2md(cmd::html2md::Args),
    /// Structural AST search across files / directories.
    AstGrep(cmd::ast::AstGrepArgs),
    /// Structural AST edit (dry-run by default).
    AstEdit(cmd::ast::AstEditArgs),
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Hash(args) => cmd::hash::run(args),
        Command::Grep(args) => cmd::grep::run(args),
        Command::Summary(args) => cmd::summary::run(args),
        Command::Html2md(args) => cmd::html2md::run(args),
        Command::AstGrep(args) => cmd::ast::grep_run(args),
        Command::AstEdit(args) => cmd::ast::edit_run(args),
    }
}
