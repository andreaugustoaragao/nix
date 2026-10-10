//! `collapse_repeated`: collapse N identical adjacent lines.
//!
//! Output style: a run of N >= 2 identical adjacent lines becomes the line
//! once, with ` (×N)` appended. Non-repeated lines pass through unchanged.
//! Line ordering is preserved.

/// Collapse runs of identical adjacent lines.
///
/// The trailing newline is always emitted after each output line so the
/// result round-trips through `lines()` cleanly. Empty input returns an
/// empty string (no synthetic newline).
pub fn collapse_repeated(input: &str) -> String {
    if input.is_empty() {
        return String::new();
    }
    let mut out = String::with_capacity(input.len());
    let mut iter = input.lines().peekable();
    while let Some(line) = iter.next() {
        let mut count: usize = 1;
        while iter.peek() == Some(&line) {
            iter.next();
            count += 1;
        }
        out.push_str(line);
        if count >= 2 {
            out.push_str(&format!(" (×{count})"));
        }
        out.push('\n');
    }
    out
}

/// Group consecutive routine log messages, ignoring only timestamps and the
/// sequence counter of a recognized heartbeat. Identifiers stay significant.
pub fn collapse_logs(input: &str) -> String {
    use std::sync::LazyLock;
    static TIMESTAMP: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(
            r"^\[?\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?\]?\s+",
        )
        .unwrap()
    });
    static HEARTBEAT: LazyLock<regex::Regex> = LazyLock::new(|| {
        regex::Regex::new(r"^(INFO heartbeat(?: healthy)? )sequence=\d+$").unwrap()
    });
    static LONG_RUN: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"[^\s]{512,}").unwrap());
    let key = |line: &str| {
        let message = TIMESTAMP.replace(line, "");
        HEARTBEAT.replace(&message, "${1}sequence=*").into_owned()
    };
    let mut out = String::new();
    let mut lines = input.lines().peekable();
    while let Some(line) = lines.next() {
        let normalized = key(line);
        let mut count = 1;
        while lines.peek().is_some_and(|next| key(next) == normalized) {
            lines.next();
            count += 1;
        }
        // Bound repeated-character payloads without hiding surrounding fields.
        let rendered = LONG_RUN.replace_all(line, |caps: &regex::Captures<'_>| {
            let word = &caps[0];
            let first = word.chars().next().unwrap();
            if word.chars().all(|c| c == first) {
                format!("{first}[repeated {} times]", word.chars().count())
            } else {
                word.to_owned()
            }
        });
        let tokens: Vec<&str> = rendered.split_inclusive(char::is_whitespace).collect();
        let mut n = 0;
        while n < tokens.len() {
            let start = n;
            n += 1;
            while n < tokens.len() && tokens[n] == tokens[start] {
                n += 1;
            }
            let count = n - start;
            if count >= 4 && tokens[start].len() * count > tokens[start].len() + 24 {
                out.push_str(tokens[start].trim_end());
                out.push_str(&format!(" [×{count} tokens] "));
            } else {
                for token in &tokens[start..n] {
                    out.push_str(token);
                }
            }
        }
        if count > 1 {
            out.push_str(&format!(
                " (×{count}; timestamps/heartbeat sequence may differ)"
            ));
        }
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_returns_empty() {
        assert_eq!(collapse_repeated(""), "");
    }

    #[test]
    fn single_line_passes_through() {
        assert_eq!(collapse_repeated("hello"), "hello\n");
    }

    #[test]
    fn no_repeats_passes_through() {
        let input = "a\nb\nc\n";
        assert_eq!(collapse_repeated(input), "a\nb\nc\n");
    }

    #[test]
    fn two_adjacent_lines_collapse() {
        assert_eq!(collapse_repeated("dup\ndup\n"), "dup (×2)\n");
    }

    #[test]
    fn three_adjacent_lines_collapse() {
        assert_eq!(collapse_repeated("dup\ndup\ndup\n"), "dup (×3)\n");
    }

    #[test]
    fn non_adjacent_lines_do_not_collapse() {
        // a/b/a is not a run: ordering preserved, no collapse.
        let input = "a\nb\na\n";
        assert_eq!(collapse_repeated(input), "a\nb\na\n");
    }

    #[test]
    fn multiple_runs_collapse_independently() {
        let input = "a\na\nb\nc\nc\nc\nd\n";
        let want = "a (×2)\nb\nc (×3)\nd\n";
        assert_eq!(collapse_repeated(input), want);
    }

    #[test]
    fn preserves_line_order() {
        let input = "x\ny\ny\nz\n";
        assert_eq!(collapse_repeated(input), "x\ny (×2)\nz\n");
    }

    #[test]
    fn handles_empty_lines_as_lines() {
        // Blank lines repeating still collapse — they are distinct lines too.
        let input = "\n\n\n";
        assert_eq!(collapse_repeated(input), " (×3)\n");
    }
}
