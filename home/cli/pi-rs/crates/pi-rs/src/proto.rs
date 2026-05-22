//! Stdout JSON envelope shared by structured subcommands.
//!
//! Shape:
//!
//! ```json
//! {"content": "model-facing text", "details": {arbitrary structured data}}
//! ```
//!
//! The TS extension passes `content` directly to the LLM and forwards
//! `details` to its tool-result `details` field for TUI rendering. The model
//! never parses JSON, so the envelope cost is paid only by the TS side.

use std::io::{self, Write};

use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Serialize)]
pub struct Envelope<'a> {
    /// Text the model consumes. Should already use omp-style hashline
    /// formatting (`LINE+HASH|TEXT`, grouped-file headings, etc.) when the
    /// tool is one the model interacts with directly.
    pub content: &'a str,
    /// Structured metadata for the TS extension layer.
    pub details: Value,
}

/// Write a JSON envelope to stdout. Always emits a single line and flushes.
pub fn emit(content: &str, details: Value) -> anyhow::Result<()> {
    let env = Envelope { content, details };
    let stdout = io::stdout();
    let mut out = stdout.lock();
    serde_json::to_writer(&mut out, &env)?;
    out.write_all(b"\n")?;
    out.flush()?;
    Ok(())
}
