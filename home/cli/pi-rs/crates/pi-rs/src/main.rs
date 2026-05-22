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
//!
//! ## Origin notice
//!
//! The `compress::`, `rewrite::`, and `cmd::filters::` modules — and the
//! per-tool wrappers (`pi-rs git`, `pi-rs cargo`, `pi-rs pytest`, etc.) they
//! support — were derived from `rtk-ai/rtk` @ tag `v0.40.0`
//! (https://github.com/rtk-ai/rtk), licensed Apache-2.0. See
//! `LICENSES/Apache-2.0.txt` and `NOTICE` at the workspace root. The fork is
//! a one-time import; this tree evolves independently from upstream and does
//! not track new releases.

use clap::{Parser, Subcommand};

mod cmd;
mod compress;
mod hashline;
mod proto;
mod rewrite;

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
    /// Apply the rewrite oracle to a shell command string.
    Rewrite(cmd::rewrite::RewriteArgs),
    /// AI-agent bash hook protocol adapter (claude | cursor).
    Hook(cmd::hook::HookArgs),

    // External-tool wrappers.
    /// Compact `git` (status, diff, log, show; passthrough otherwise).
    Git(cmd::filters::git::GitArgs),
    /// Compact `cargo` (test/build/check/clippy/run; passthrough otherwise).
    Cargo(cmd::filters::cargo::CargoArgs),
    /// Compact `gh` (GitHub CLI; passthrough with truncation).
    Gh(cmd::filters::gh::GhArgs),
    /// Compact `npm` (install/test/run; passthrough otherwise).
    Npm(cmd::filters::npm::NpmArgs),
    /// Compact `pnpm` (install/test/run; passthrough otherwise).
    Pnpm(cmd::filters::pnpm::PnpmArgs),
    /// Compact `yarn` (install/test/run; passthrough otherwise).
    Yarn(cmd::filters::yarn::YarnArgs),
    /// Compact `pytest` (failures-only on the test runner).
    Pytest(cmd::filters::pytest::PytestArgs),
    /// Compact `docker` (logs deduped, lists truncated).
    Docker(cmd::filters::docker::DockerArgs),
    /// Compact `kubectl` (logs deduped, lists truncated).
    Kubectl(cmd::filters::kubectl::KubectlArgs),

    // LLM-facing primitives.
    /// Smart file read with `--level` for signature-only mode.
    Read(cmd::filters::read::ReadArgs),
    /// Compact directory listing with grouping.
    Ls(cmd::filters::ls::LsArgs),
    /// Compact `find` with directory grouping.
    Find(cmd::filters::find::FindArgs),
    /// JSON structure-only view (drops scalar values).
    Json(cmd::filters::json::JsonArgs),
    /// Deduplicated log viewer.
    Log(cmd::filters::log::LogArgs),
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
        Command::Rewrite(args) => cmd::rewrite::run(args),
        Command::Hook(args) => cmd::hook::run(args),
        Command::Git(args) => cmd::filters::git::run(args),
        Command::Cargo(args) => cmd::filters::cargo::run(args),
        Command::Gh(args) => cmd::filters::gh::run(args),
        Command::Npm(args) => cmd::filters::npm::run(args),
        Command::Pnpm(args) => cmd::filters::pnpm::run(args),
        Command::Yarn(args) => cmd::filters::yarn::run(args),
        Command::Pytest(args) => cmd::filters::pytest::run(args),
        Command::Docker(args) => cmd::filters::docker::run(args),
        Command::Kubectl(args) => cmd::filters::kubectl::run(args),
        Command::Read(args) => cmd::filters::read::run(args),
        Command::Ls(args) => cmd::filters::ls::run(args),
        Command::Find(args) => cmd::filters::find::run(args),
        Command::Json(args) => cmd::filters::json::run(args),
        Command::Log(args) => cmd::filters::log::run(args),
    }
}
