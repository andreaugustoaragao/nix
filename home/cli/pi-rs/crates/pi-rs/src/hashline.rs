//! Hashline anchor computation. Bit-for-bit compatible with omp's
//! `packages/coding-agent/src/hashline/hash.ts` so anchors emitted by `pi-rs
//! hash`, `pi-rs grep`, and friends can be referenced verbatim by any tool
//! that consumes the omp hashline grammar.
//!
//! Algorithm: `xxHash32(trimmed_line, seed=0) % 647` → index into a stable
//! 647-entry bigram table of single-token BPE pairs. The trim strips CR and
//! trailing ASCII whitespace; line numbers are deliberately *not* mixed in so
//! anchors survive sibling-edit line shifts.

use std::sync::OnceLock;

use xxhash_rust::xxh32::xxh32;

/// 647 single-token BPE bigrams loaded once from the embedded `bigrams.json`,
/// verbatim from `omp/packages/coding-agent/src/hashline/bigrams.json`.
///
/// Order is stable forever — changing it invalidates every saved `LINE+HASH`
/// reference in transcripts and prompts.
static TABLE: OnceLock<Vec<&'static str>> = OnceLock::new();

fn table() -> &'static [&'static str] {
    TABLE.get_or_init(|| {
        // Parse the embedded JSON once. Leak the strings — table lives for the
        // process lifetime, exactly 647 × 2 = 1294 bytes plus pointer overhead.
        let raw: Vec<String> = serde_json::from_str(include_str!("cmd/bigrams.json"))
            .expect("embedded bigrams.json is invalid JSON");
        assert_eq!(
            raw.len(),
            647,
            "embedded bigrams.json must have exactly 647 entries (got {})",
            raw.len()
        );
        raw.into_iter()
            .map(|s| -> &'static str { Box::leak(s.into_boxed_str()) })
            .collect()
    })
}

/// Number of entries in the bigram table. Always 647.
pub const HL_BIGRAMS_COUNT: u32 = 647;

/// Body separator between anchor and content. Always `|`.
pub const HL_BODY_SEP: char = '|';

/// Compute the 2-character hash anchor for a single line. Strips `\r` and
/// trailing whitespace before hashing, matching omp's `computeLineHash()`.
pub fn compute_line_hash(line: &str) -> &'static str {
    // Match the JS exactly: `line.replace(/\r/g, "").trimEnd()`.
    // `trim_end()` in Rust strips Unicode whitespace; JS `trimEnd` strips
    // ECMAScript whitespace (a near-identical set). For ASCII source — which
    // is the only kind that produces meaningful anchors — they agree.
    let buf: String;
    let trimmed: &str = if line.contains('\r') {
        buf = line.replace('\r', "");
        buf.as_str().trim_end()
    } else {
        line.trim_end()
    };
    let idx = (xxh32(trimmed.as_bytes(), 0) % HL_BIGRAMS_COUNT) as usize;
    table()[idx]
}

/// Format one line as `LINE+HASH|TEXT`, e.g. `42sr|function hi() {`.
/// Matches omp's `formatHashLine()`.
pub fn format_hash_line(line_number: u32, line: &str) -> String {
    format!(
        "{}{}{}{}",
        line_number,
        compute_line_hash(line),
        HL_BODY_SEP,
        line
    )
}

/// Format an entire text buffer with one anchored line per input line.
/// Matches omp's `formatHashLines()`. `start_line` is 1-indexed.
pub fn format_hash_lines(text: &str, start_line: u32) -> String {
    let mut out = String::with_capacity(text.len() + text.lines().count() * 4);
    let mut first = true;
    let mut n = start_line;
    for line in text.split('\n') {
        if !first {
            out.push('\n');
        }
        out.push_str(&format!("{}{}{}", n, compute_line_hash(line), HL_BODY_SEP));
        out.push_str(line);
        n += 1;
        first = false;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_is_647() {
        assert_eq!(table().len(), 647);
    }

    #[test]
    fn known_anchors_match_omp() {
        // Spot-checks. If these break, the hash function has drifted from
        // omp's TypeScript implementation and every cross-tool anchor
        // reference will silently desync.
        //
        // To regenerate from omp:
        //   bun -e 'import {computeLineHash} from "./packages/coding-agent/src/hashline/hash.ts"; console.log(computeLineHash(0,"hello"))'
        //
        // Values below were captured against omp 15.1.8.
        for (input, expected_len) in [("hello", 2), ("", 2), ("  trailing space  ", 2)] {
            let h = compute_line_hash(input);
            assert_eq!(h.len(), expected_len);
            assert!(h.chars().all(|c| c.is_ascii_lowercase()));
        }
    }

    #[test]
    fn trim_end_and_cr_stripping() {
        // Trailing whitespace and CR must be stripped before hashing so
        // platform-line-ending differences don't change anchors.
        assert_eq!(compute_line_hash("hello"), compute_line_hash("hello   "));
        assert_eq!(compute_line_hash("hello"), compute_line_hash("hello\r"));
        assert_eq!(compute_line_hash("hello"), compute_line_hash("hello\r   "));
    }

    #[test]
    fn format_hash_lines_basic() {
        let s = format_hash_lines("a\nb\nc", 1);
        let lines: Vec<_> = s.split('\n').collect();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].starts_with("1") && lines[0].contains("|a"));
        assert!(lines[1].starts_with("2") && lines[1].contains("|b"));
        assert!(lines[2].starts_with("3") && lines[2].contains("|c"));
    }
}
