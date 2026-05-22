//! `pi-rs html2md` — convert HTML on stdin to Markdown on stdout.
//!
//! Wraps `html-to-markdown-rs` (same crate omp uses) with omp's "aggressive
//! preprocessing" preset by default: drop navigation, forms, headers,
//! footers. The model-facing output is the Markdown body verbatim.

use std::io::{self, Read, Write};

use clap::Args as ClapArgs;
use html_to_markdown_rs::{
    convert, ConversionOptions, PreprocessingOptions, PreprocessingPreset,
};

use crate::compress::tee::{TruncateRequest, truncate_with_tee};

#[derive(ClapArgs, Debug)]
pub struct Args {
    /// Skip image references in the output.
    #[arg(long)]
    pub skip_images: bool,

    /// Disable aggressive content cleanup (navigation/forms/headers/footers
    /// stripping). Useful for partial-page extractions.
    #[arg(long)]
    pub no_clean: bool,
}

pub fn run(args: Args) -> anyhow::Result<()> {
    let mut html = String::new();
    io::stdin().read_to_string(&mut html)?;

    let opts = ConversionOptions {
        skip_images: args.skip_images,
        preprocessing: PreprocessingOptions {
            enabled: !args.no_clean,
            preset: PreprocessingPreset::Aggressive,
            remove_navigation: true,
            remove_forms: true,
        },
        ..Default::default()
    };

    let md = convert(&html, Some(opts))
        .map_err(|e| anyhow::anyhow!("html-to-markdown conversion failed: {e}"))?;

    // Tee fallback: huge pages (multi-thousand-line markdown) get
    // head+tail truncated with the full markdown saved to disk. The LLM
    // can `pi-rs read <tee_path>` to recover the unfiltered version. The
    // budget is generous (1000 lines) because web pages converted to
    // markdown are the intended payload of this command.
    let r = truncate_with_tee(TruncateRequest {
        content: &md,
        head_lines: 700,
        tail_lines: 300,
        cmd_hint: "html2md",
        tee_dir: None,
    })?;

    let stdout = io::stdout();
    let mut out = stdout.lock();
    out.write_all(r.content.as_bytes())?;
    if !r.content.ends_with('\n') {
        out.write_all(b"\n")?;
    }
    Ok(())
}
