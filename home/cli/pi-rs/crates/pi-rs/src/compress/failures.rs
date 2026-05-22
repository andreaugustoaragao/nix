//! Test-runner output shapes and format helper.
//!
//! Per-language wrappers (cargo, pytest, vitest, go test, …) parse their
//! runner-specific output into [`TestSummary`] and call
//! [`format_test_summary`] for the compressed model-facing string. This
//! primitive owns the *shape* of a failure report; parsers live in the
//! wrappers themselves so each tool's format quirks stay local.

use serde::Serialize;

/// One failing test, parsed from runner output.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct TestFailure {
    /// Logical test identifier as the runner names it. Examples:
    /// `tests::foo::test_bar`, `FooTest#testBaz`, `tests/foo.py::test_bar`.
    pub name: String,
    /// Source file the failure points at, when discoverable.
    pub file: Option<String>,
    /// Source line, when discoverable.
    pub line: Option<u32>,
    /// Assertion failure / panic / stderr blob. Multi-line allowed; the
    /// formatter indents continuation lines.
    pub message: String,
}

/// Aggregate result of a runner invocation. `total = passed + failed + skipped`
/// is the convention; wrappers populate whatever subset they can extract.
#[derive(Debug, Clone, Serialize, PartialEq, Eq, Default)]
pub struct TestSummary {
    pub total: u32,
    pub passed: u32,
    pub failed: u32,
    pub skipped: u32,
    pub failures: Vec<TestFailure>,
}

/// Render a [`TestSummary`] to the compact model-facing form.
///
/// Shape on success:
///
/// ```text
/// PASS 42/45 (3 skipped)
/// ```
///
/// Shape on failure (newline-terminated):
///
/// ```text
/// FAILED 2/45 (40 passed, 3 skipped)
///   tests::foo::test_bar  src/foo.rs:42
///     assertion `left == right` failed
///       left: 1
///       right: 2
///   tests::baz::test_qux
///     panicked at 'oops'
/// ```
pub fn format_test_summary(summary: &TestSummary) -> String {
    if summary.failed == 0 && summary.failures.is_empty() {
        return format!(
            "PASS {}/{} ({} skipped)\n",
            summary.passed, summary.total, summary.skipped
        );
    }

    let mut out = format!(
        "FAILED {}/{} ({} passed, {} skipped)\n",
        summary.failed, summary.total, summary.passed, summary.skipped
    );
    for failure in &summary.failures {
        let loc = match (&failure.file, failure.line) {
            (Some(f), Some(l)) => format!("  {f}:{l}"),
            (Some(f), None) => format!("  {f}"),
            _ => String::new(),
        };
        out.push_str("  ");
        out.push_str(&failure.name);
        out.push_str(&loc);
        out.push('\n');
        if !failure.message.is_empty() {
            for line in failure.message.lines() {
                out.push_str("    ");
                out.push_str(line);
                out.push('\n');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pass_summary_is_one_line() {
        let s = TestSummary {
            total: 12,
            passed: 12,
            failed: 0,
            skipped: 0,
            failures: vec![],
        };
        assert_eq!(format_test_summary(&s), "PASS 12/12 (0 skipped)\n");
    }

    #[test]
    fn pass_summary_reports_skipped_count() {
        let s = TestSummary {
            total: 15,
            passed: 12,
            failed: 0,
            skipped: 3,
            failures: vec![],
        };
        assert_eq!(format_test_summary(&s), "PASS 12/15 (3 skipped)\n");
    }

    #[test]
    fn failure_summary_header() {
        let s = TestSummary {
            total: 10,
            passed: 8,
            failed: 2,
            skipped: 0,
            failures: vec![
                TestFailure {
                    name: "test_a".into(),
                    file: None,
                    line: None,
                    message: String::new(),
                },
                TestFailure {
                    name: "test_b".into(),
                    file: None,
                    line: None,
                    message: String::new(),
                },
            ],
        };
        let out = format_test_summary(&s);
        assert!(out.starts_with("FAILED 2/10 (8 passed, 0 skipped)\n"));
    }

    #[test]
    fn failure_with_file_and_line_renders_location() {
        let s = TestSummary {
            total: 1,
            passed: 0,
            failed: 1,
            skipped: 0,
            failures: vec![TestFailure {
                name: "foo".into(),
                file: Some("src/a.rs".into()),
                line: Some(42),
                message: "boom".into(),
            }],
        };
        let out = format_test_summary(&s);
        assert!(out.contains("foo  src/a.rs:42\n"));
        assert!(out.contains("    boom\n"));
    }

    #[test]
    fn failure_with_only_file_omits_line_suffix() {
        let s = TestSummary {
            total: 1,
            passed: 0,
            failed: 1,
            skipped: 0,
            failures: vec![TestFailure {
                name: "foo".into(),
                file: Some("src/a.rs".into()),
                line: None,
                message: String::new(),
            }],
        };
        let out = format_test_summary(&s);
        assert!(out.contains("foo  src/a.rs\n"));
        assert!(!out.contains(":")); // no line suffix at all
    }

    #[test]
    fn failure_without_location_omits_it() {
        let s = TestSummary {
            total: 1,
            passed: 0,
            failed: 1,
            skipped: 0,
            failures: vec![TestFailure {
                name: "foo".into(),
                file: None,
                line: None,
                message: String::new(),
            }],
        };
        let out = format_test_summary(&s);
        assert!(out.contains("  foo\n"));
    }

    #[test]
    fn multiline_message_is_indented() {
        let s = TestSummary {
            total: 1,
            passed: 0,
            failed: 1,
            skipped: 0,
            failures: vec![TestFailure {
                name: "foo".into(),
                file: None,
                line: None,
                message: "line 1\nline 2\nline 3".into(),
            }],
        };
        let out = format_test_summary(&s);
        assert!(out.contains("    line 1\n"));
        assert!(out.contains("    line 2\n"));
        assert!(out.contains("    line 3\n"));
    }

    #[test]
    fn failed_zero_but_failures_nonempty_still_treated_as_failed() {
        // Defensive: if a wrapper populated `failures` but forgot to bump
        // `failed`, we still take the failure path.
        let s = TestSummary {
            total: 1,
            passed: 0,
            failed: 0,
            skipped: 0,
            failures: vec![TestFailure {
                name: "foo".into(),
                file: None,
                line: None,
                message: String::new(),
            }],
        };
        let out = format_test_summary(&s);
        assert!(out.starts_with("FAILED 0/1"));
    }
}
