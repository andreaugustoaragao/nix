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

    let stdout = io::stdout();
    let mut out = stdout.lock();
    out.write_all(md.as_bytes())?;
    if !md.ends_with('\n') {
        out.write_all(b"\n")?;
    }
    Ok(())
}
