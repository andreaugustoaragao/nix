//! Pytest wrapper: retain caller arguments and compact recognized progress.
//! Failure blocks, warnings, unknown plugin output and explicit verbosity remain.

use clap::Args;

use super::{DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES, run_filtered};

#[derive(Args, Debug)]
pub struct PytestArgs {
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub args: Vec<String>,
}

pub fn run(args: PytestArgs) -> anyhow::Result<()> {
    let refs: Vec<&str> = args.args.iter().map(String::as_str).collect();
    let code = run_filtered(
        "pytest",
        &refs,
        "pytest",
        DEFAULT_HEAD_LINES,
        DEFAULT_TAIL_LINES,
    )?;
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}

/// Remove only recognized progress rows. Failure, warning and plugin output
/// remain verbatim, including everything after the first diagnostic section.
pub fn summarize(text: &str) -> String {
    if !text
        .lines()
        .any(|l| l.contains(" passed") || l.contains(" failed") || l.contains(" error"))
    {
        return text.to_owned();
    }
    let progress =
        regex::Regex::new(r"^(?:[^\s]+\.py(?:::[^ ]+)?\s+)?[.sFxEX]+(?:\s+\[\s*\d+%\])?\s*$")
            .unwrap();
    let verbose =
        regex::Regex::new(r"^\S+\.py::\S+\s+(?:PASSED|SKIPPED|XFAIL)(?:\s+\[\s*\d+%\])?\s*$")
            .unwrap();
    let session = text
        .lines()
        .any(|line| line.trim_matches('=').trim() == "test session starts");
    let result = regex::Regex::new(r"^=+\s+\d+ (?:passed|failed|skipped|error).+\s+=+$").unwrap();
    let mut diagnostics = false;
    let mut out = String::new();
    for line in text.split_inclusive('\n') {
        if line.starts_with('=')
            && (line.contains("FAILURES")
                || line.contains("ERRORS")
                || line.contains("warnings summary"))
        {
            diagnostics = true;
        }
        if !diagnostics && (progress.is_match(line.trim_end()) || verbose.is_match(line.trim_end()))
        {
            continue;
        }
        if session
            && !diagnostics
            && (line.trim().is_empty()
                || line.trim_matches(['=', '\n', ' ']) == "test session starts"
                || line.starts_with("platform ")
                || line.starts_with("rootdir: ")
                || (line.starts_with("collected ")
                    && (line.trim_end().ends_with(" items") || line.trim_end().ends_with(" item"))))
        {
            continue;
        }
        if result.is_match(line.trim_end()) {
            out.push_str(line.trim_matches(['=', '\n', ' ']));
            out.push('\n');
        } else {
            out.push_str(line);
        }
    }
    out
}
