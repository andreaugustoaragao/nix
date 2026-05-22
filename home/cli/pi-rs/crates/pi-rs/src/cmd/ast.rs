//! `pi-rs ast-grep` and `pi-rs ast-edit` — structural search/rewrite.
//!
//! The vendored `pi_ast::ops` module exposes the primitives (language
//! resolution, pattern compilation, match collection, rewrite application).
//! High-level file-walking orchestration lives in omp's
//! `crates/pi-natives/src/ast.rs` and is heavily entangled with the napi
//! task layer, so we port it explicitly here rather than wrap.
//!
//! TODO(v2): Implement orchestration loops over `WalkBuilder` for both
//! grep and edit, with per-file limits, dry-run/apply, and parse-error
//! collection.

use clap::Args as ClapArgs;
use serde_json::json;

use crate::proto;

#[derive(ClapArgs, Debug)]
pub struct AstGrepArgs {
    /// Structural pattern (ast-grep syntax). Reserved for v2.
    #[arg(long, short = 'e')]
    pub pattern: String,
    /// One or more files / directories / globs. Reserved for v2.
    #[arg(long = "path", short = 'p', required = true, num_args = 1.., action = clap::ArgAction::Append)]
    pub paths: Vec<String>,
    /// Language override. Reserved for v2.
    #[arg(long)]
    pub lang: Option<String>,
}

#[derive(ClapArgs, Debug)]
pub struct AstEditArgs {
    /// Rewrite rule `pat=>out`. Reserved for v2.
    #[arg(long = "op", required = true, num_args = 1.., action = clap::ArgAction::Append)]
    pub ops: Vec<String>,
    /// One or more files / directories / globs. Reserved for v2.
    #[arg(long = "path", short = 'p', required = true, num_args = 1.., action = clap::ArgAction::Append)]
    pub paths: Vec<String>,
    /// Language override. Reserved for v2.
    #[arg(long)]
    pub lang: Option<String>,
    /// Apply edits to disk (default: dry-run). Reserved for v2.
    #[arg(long)]
    pub apply: bool,
}

pub fn grep_run(_args: AstGrepArgs) -> anyhow::Result<()> {
    proto::emit(
        "ast-grep is not implemented yet in pi-rs v1; use the `astgrep` extension or `sg` directly",
        json!({ "stage": "stub", "version": "v1" }),
    )
}

pub fn edit_run(_args: AstEditArgs) -> anyhow::Result<()> {
    proto::emit(
        "ast-edit is not implemented yet in pi-rs v1",
        json!({ "stage": "stub", "version": "v1" }),
    )
}
