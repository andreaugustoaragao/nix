//! `strip_progress`: drop progress-bar lines and transient terminal noise.
//!
//! Targets four classes of noise:
//!
//! 1. ASCII progress bars: lines whose first non-whitespace content is `[`
//!    followed by progress characters and a closing `]`.
//! 2. Git pack progress: `(remote: )?(Counting|Compressing|…) (objects|files):`.
//! 3. Bare percent lines: `47%` or `47% (12/27)` with optional surrounding
//!    whitespace.
//! 4. Throughput lines: any line containing `<number> KB/s` etc.
//!
//! Carriage-return overwrites are collapsed first: each `\n`-terminated line
//! is reduced to its last `\r`-separated segment so progress bars that share
//! a single line via `\r` resolve to their final state before pattern
//! matching.

use regex::Regex;
use std::sync::OnceLock;

fn progress_patterns() -> &'static [Regex] {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        vec![
            // ASCII progress bars: leading optional whitespace + [<progress chars>]
            // Char class includes #=>.*| and whitespace; permissive on purpose
            // since trackers vary across tools (cargo, npm, pip, apt, etc.).
            Regex::new(r"^\s*\[[#=>.*|\s]+\]").unwrap(),
            // Git pack-protocol progress messages, with or without `remote: ` prefix.
            Regex::new(
                r"^(remote: )?(Counting|Compressing|Resolving|Receiving|Writing|Enumerating|Updating) (objects|files):",
            )
            .unwrap(),
            // Bare percent line: optional fraction in parens, surrounded by whitespace only.
            Regex::new(r"^\s*\d{1,3}%\s*(\(\d+/\d+\))?\s*$").unwrap(),
            // Throughput suffix anywhere in the line.
            Regex::new(r"\b\d+(\.\d+)?\s*[KMG]i?B/s\b").unwrap(),
        ]
    })
}

/// Strip lines that match any of the progress patterns. Carriage-return
/// overwrites collapse first so streamed progress bars resolve to their
/// final state before pattern matching.
pub fn strip_progress(input: &str) -> String {
    let patterns = progress_patterns();
    let mut out = String::with_capacity(input.len());
    for raw_line in input.split_inclusive('\n') {
        let trailing_newline = raw_line.ends_with('\n');
        // Collapse CR overwrites: keep only the final \r-segment.
        let logical = raw_line
            .trim_end_matches('\n')
            .trim_end_matches('\r')
            .rsplit('\r')
            .next()
            .unwrap_or("");

        if patterns.iter().any(|p| p.is_match(logical)) {
            continue;
        }
        out.push_str(logical);
        if trailing_newline {
            out.push('\n');
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normal_text_passes_through() {
        let input = "Building project...\nTests passed: 12\n";
        assert_eq!(strip_progress(input), input);
    }

    #[test]
    fn strips_ascii_progress_bar() {
        let input = "Building\n[####>     ] 47%\nDone\n";
        assert_eq!(strip_progress(input), "Building\nDone\n");
    }

    #[test]
    fn strips_progress_bar_with_leading_whitespace() {
        let input = "Building\n  [====]  47%\nDone\n";
        assert_eq!(strip_progress(input), "Building\nDone\n");
    }

    #[test]
    fn keeps_brackets_that_arent_progress() {
        // [INFO] is not progress — must keep.
        let input = "[INFO] starting\n[WARN] careful\n";
        assert_eq!(strip_progress(input), input);
    }

    #[test]
    fn strips_git_counting_objects() {
        let input = "Cloning...\nCounting objects: 100% (5/5), done.\nDone\n";
        assert_eq!(strip_progress(input), "Cloning...\nDone\n");
    }

    #[test]
    fn strips_remote_git_progress() {
        let input = "remote: Counting objects: 100% (5/5)\n\
                     remote: Compressing objects: 100% (4/4)\n\
                     remote: Total 5 (delta 0)\n";
        // The 3rd line is not a tracked verb, kept.
        let expected = "remote: Total 5 (delta 0)\n";
        assert_eq!(strip_progress(input), expected);
    }

    #[test]
    fn strips_bare_percent_line() {
        let input = "Working\n47%\n100% (10/10)\nDone\n";
        assert_eq!(strip_progress(input), "Working\nDone\n");
    }

    #[test]
    fn percent_with_prefix_is_kept() {
        // "Loading 47%" has prefix text — not a bare percent line.
        let input = "Loading 47%\n";
        assert_eq!(strip_progress(input), input);
    }

    #[test]
    fn strips_throughput_line() {
        let input = "Downloading\n5.2 MB/s 47% complete\nReady\n";
        assert_eq!(strip_progress(input), "Downloading\nReady\n");
    }

    #[test]
    fn carriage_return_overwrites_collapse_before_matching() {
        // Streamed progress that ends with the final state. The \r-prefixed
        // earlier segments are discarded, then the final state ("Done") is
        // matched against the patterns. Final isn't progress, so kept.
        let input = "[#>  ] 20%\r[###>] 60%\rDone\n";
        assert_eq!(strip_progress(input), "Done\n");
    }

    #[test]
    fn carriage_return_progress_strips_when_final_is_progress() {
        let input = "[#>  ] 20%\r[####] 100%\n";
        assert_eq!(strip_progress(input), "");
    }

    #[test]
    fn empty_input() {
        assert_eq!(strip_progress(""), "");
    }
}
