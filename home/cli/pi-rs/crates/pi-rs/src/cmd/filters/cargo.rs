//! Cargo wrapper: compact recognized build/libtest output, retain diagnostics.
//! Explicit message formats and live runs pass through unchanged.

use clap::Args;

use super::{DEFAULT_HEAD_LINES, DEFAULT_TAIL_LINES, run_filtered};

#[derive(Args, Debug)]
pub struct CargoArgs {
    /// Args passed verbatim to `cargo`.
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub args: Vec<String>,
}

pub fn run(args: CargoArgs) -> anyhow::Result<()> {
    let refs: Vec<&str> = args.args.iter().map(|s| s.as_str()).collect();
    let hint = match args.args.first().map(String::as_str) {
        Some(sub) => format!("cargo_{sub}"),
        None => "cargo".into(),
    };
    let code = run_filtered(
        "cargo",
        &refs,
        &hint,
        DEFAULT_HEAD_LINES,
        DEFAULT_TAIL_LINES,
    )?;
    if code != 0 {
        std::process::exit(code);
    }
    Ok(())
}

/// Summarize known Cargo and libtest noise, never unrecognized diagnostics.
pub fn summarize(text: &str) -> String {
    let build =
        regex::Regex::new(r"^\s+(?:Compiling|Checking|Fresh|Downloading) \S+ v\S+").unwrap();
    let passed = regex::Regex::new(r"^test .+ \.\.\. (?:ok|ignored)(?:, .*)?$").unwrap();
    let success = regex::Regex::new(r"^test result: ok\. (\d+) passed; 0 failed; (\d+) ignored; 0 measured; 0 filtered out; finished in .+$").unwrap();
    let mut removed = 0;
    let mut diagnostics = false;
    let mut out = String::new();
    for line in text.split_inclusive('\n') {
        let trimmed = line.trim_end();
        if trimmed == "failures:" {
            diagnostics = true;
        }
        if !diagnostics && (build.is_match(trimmed) || passed.is_match(trimmed)) {
            removed += 1;
            continue;
        }
        if let Some(captures) = success.captures(trimmed)
            && let (Ok(passed), Ok(skipped)) =
                (captures[1].parse::<u32>(), captures[2].parse::<u32>())
            && let Some(total) = passed.checked_add(skipped)
        {
            let summary = crate::compress::failures::TestSummary {
                total,
                passed,
                skipped,
                ..Default::default()
            };
            out.push_str("test result: ok. ");
            out.push_str(&crate::compress::failures::format_test_summary(&summary));
            removed += 1;
            continue;
        }
        out.push_str(line);
    }
    if removed > 0 {
        out.push_str(&format!(
            "[{removed} build/progress or passing-test lines omitted]\n"
        ));
    }
    out
}
