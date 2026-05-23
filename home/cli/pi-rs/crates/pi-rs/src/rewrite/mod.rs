//! Rewrite oracle: maps shell commands to their pi-rs-compressed equivalents.
//!
//! Consumed by `pi-rs rewrite "<cmd>"` (the agent-facing API) and by
//! `pi-rs hook claude|cursor` (the protocol-specific adapters). Per-agent
//! shim scripts and the pi TS extension all funnel through the same
//! [`rewrite()`] function.
//!
//! Behavior (aggressive, but pipeline-safe):
//!
//! 1. If the raw command contains any unquoted shell operator (`|`, `&`,
//!    `;`, `<`, `>`, `` ` ``, `$(`, `(`, `)`), passthrough. Rewriting
//!    `argv[0]` would feed the rest of the pipeline into the wrong tool —
//!    e.g. `git ls-files | grep foo` should not become
//!    `pi-rs git ls-files '|' grep foo`.
//! 2. Tokenize the command string via [`shell_words::split`]. Malformed
//!    quoting → [`Decision::Passthrough`] (never crash a hook on bad input).
//! 3. Take the basename of `argv[0]`. `/usr/bin/git` and `git` resolve the
//!    same way.
//! 4. If the basename is in [`config::Config::exclude`], passthrough.
//! 5. Look up the basename in [`rules::RULES`]. If no entry, passthrough.
//! 6. If the rule has an [`rules::Rule::argv_compatible`] predicate and it
//!    rejects `argv[1..]`, passthrough. This protects the LLM from
//!    `ls -la`-style invocations that the narrow pi-rs primitives can't
//!    serve.
//! 7. Otherwise: replace `argv[0]` with `pi-rs <rule.subcmd>` and re-emit
//!    via [`shell_words::join`] (which re-quotes args containing spaces).
//!
//! Wrappers that *do* accept anything (`git`, `cargo`, `gh`, …) leave
//! `argv_compatible = None` and rely on their internal external-subcommand
//! / trailing-var-arg passthrough.

pub mod config;
pub mod rules;

use config::Config;
use rules::{RULES, Rule};

/// Outcome of a rewrite lookup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// No rule matched, argv[0] was excluded, tokenization failed, or the
    /// rule's `argv_compatible` predicate rejected the shape.
    Passthrough,
    /// A rule matched. The rewritten command string is provided.
    Rewrite(String),
}

/// Apply the rewrite oracle to a shell command string.
///
/// See module-level docs for the full algorithm. Uses the global
/// [`RULES`] table; for unit-testable variants see [`rewrite_with_rules`].
pub fn rewrite(command: &str, config: &Config) -> Decision {
    rewrite_with_rules(command, RULES, config)
}

/// Variant of [`rewrite`] that takes the rules table explicitly. Used by
/// tests so coverage doesn't depend on the populated state of [`RULES`].
pub fn rewrite_with_rules(command: &str, rules: &[Rule], config: &Config) -> Decision {
    // Empty / whitespace-only → nothing to do.
    let trimmed = command.trim();
    if trimmed.is_empty() {
        return Decision::Passthrough;
    }

    // Pipelines / redirections / subshells / command substitution: hand
    // off to bash. Rewriting argv[0] in these would lose composition.
    if contains_shell_operator(trimmed) {
        return Decision::Passthrough;
    }

    // Tokenize. Malformed quoting → passthrough.
    let argv = match shell_words::split(trimmed) {
        Ok(v) if !v.is_empty() => v,
        _ => return Decision::Passthrough,
    };

    let bin = basename(&argv[0]);

    // Exclude list wins over rule lookup.
    if config.exclude.iter().any(|e| e == bin) {
        return Decision::Passthrough;
    }

    let Some(rule) = rules.iter().find(|r| r.bin == bin) else {
        return Decision::Passthrough;
    };

    // Per-rule argv shape check.
    if let Some(pred) = rule.argv_compatible
        && !pred(&argv[1..])
    {
        return Decision::Passthrough;
    }

    // Replace argv[0] with `pi-rs <subcmd>`. shell_words::join re-quotes any
    // arg that needs it (spaces, shell metacharacters, etc.).
    let mut out_argv: Vec<&str> = Vec::with_capacity(argv.len() + 1);
    out_argv.push("pi-rs");
    out_argv.push(rule.subcmd);
    for a in argv.iter().skip(1) {
        out_argv.push(a.as_str());
    }
    Decision::Rewrite(shell_words::join(out_argv))
}

/// Extract the basename of a command (last `/`-separated segment).
///
/// Examples:
/// - `git` → `git`
/// - `/usr/bin/git` → `git`
/// - `./scripts/foo.sh` → `foo.sh`
fn basename(s: &str) -> &str {
    s.rsplit('/').next().unwrap_or(s)
}

/// Detect any unquoted shell operator that means "this command is part of
/// a composition bash needs to parse".
///
/// Tracks single-quote and double-quote state so `grep 'a|b' file` is not
/// treated as a pipeline. Inside double quotes, only `$(` and `` ` ``
/// trigger (variable / command substitution) — bare `|` `>` etc. are
/// literal inside `"..."`. Backslash escapes one byte in unquoted /
/// double-quoted regions; single quotes do not honour escapes (matches
/// POSIX shell).
pub fn contains_shell_operator(command: &str) -> bool {
    let bytes = command.as_bytes();
    let mut i = 0;
    let mut in_single = false;
    let mut in_double = false;
    while i < bytes.len() {
        let c = bytes[i];
        if in_single {
            if c == b'\'' {
                in_single = false;
            }
            i += 1;
            continue;
        }
        if in_double {
            if c == b'\\' && i + 1 < bytes.len() {
                i += 2;
                continue;
            }
            if c == b'"' {
                in_double = false;
                i += 1;
                continue;
            }
            if c == b'`' {
                return true;
            }
            if c == b'$' && i + 1 < bytes.len() && bytes[i + 1] == b'(' {
                return true;
            }
            i += 1;
            continue;
        }
        // Unquoted region.
        match c {
            b'\\' if i + 1 < bytes.len() => {
                i += 2;
                continue;
            }
            b'\'' => in_single = true,
            b'"' => in_double = true,
            b'|' | b'&' | b';' | b'<' | b'>' | b'`' | b'(' | b')' => return true,
            b'$' if i + 1 < bytes.len() && bytes[i + 1] == b'(' => return true,
            _ => {}
        }
        i += 1;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg_empty() -> Config {
        Config::default()
    }

    fn cfg_excluding(s: &str) -> Config {
        Config {
            exclude: vec![s.into()],
        }
    }

    /// Predicate that always rejects, used to exercise the
    /// `argv_compatible` branch deterministically.
    fn never_ok(_: &[String]) -> bool {
        false
    }

    const TEST_RULES: &[Rule] = &[
        Rule {
            bin: "git",
            subcmd: "git",
            argv_compatible: None,
        },
        Rule {
            bin: "cat",
            subcmd: "read",
            argv_compatible: None,
        },
        Rule {
            bin: "ls",
            subcmd: "ls",
            argv_compatible: Some(never_ok),
        },
    ];

    #[test]
    fn empty_input_passes_through() {
        assert_eq!(
            rewrite_with_rules("", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
    }

    #[test]
    fn whitespace_only_passes_through() {
        assert_eq!(
            rewrite_with_rules("   ", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
    }

    #[test]
    fn unknown_command_passes_through() {
        assert_eq!(
            rewrite_with_rules("foozle bar baz", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
    }

    #[test]
    fn known_command_rewrites() {
        assert_eq!(
            rewrite_with_rules("git status", TEST_RULES, &cfg_empty()),
            Decision::Rewrite("pi-rs git status".into())
        );
    }

    #[test]
    fn rule_subcmd_can_differ_from_bin() {
        // cat → read remap: argv[0] replaced by `pi-rs read`.
        assert_eq!(
            rewrite_with_rules("cat /etc/passwd", TEST_RULES, &cfg_empty()),
            Decision::Rewrite("pi-rs read /etc/passwd".into())
        );
    }

    #[test]
    fn strips_leading_path_from_argv0() {
        // /usr/bin/git matches the `git` rule.
        assert_eq!(
            rewrite_with_rules("/usr/bin/git status", TEST_RULES, &cfg_empty()),
            Decision::Rewrite("pi-rs git status".into())
        );
    }

    #[test]
    fn exclude_list_blocks_rewrite() {
        assert_eq!(
            rewrite_with_rules("git status", TEST_RULES, &cfg_excluding("git")),
            Decision::Passthrough
        );
    }

    #[test]
    fn exclude_matches_basename_not_full_argv0() {
        // Excluding "git" should also block /usr/bin/git.
        assert_eq!(
            rewrite_with_rules("/usr/bin/git status", TEST_RULES, &cfg_excluding("git")),
            Decision::Passthrough
        );
    }

    #[test]
    fn args_with_spaces_are_requoted() {
        // shell-words::join single-quotes args containing whitespace so the
        // emitted string is shell-safe to re-execute.
        assert_eq!(
            rewrite_with_rules("git commit -m 'fix bug'", TEST_RULES, &cfg_empty()),
            Decision::Rewrite("pi-rs git commit -m 'fix bug'".into())
        );
    }

    #[test]
    fn malformed_quoting_passes_through() {
        // Unbalanced quote → shell-words returns Err → we passthrough rather
        // than crash the hook.
        assert_eq!(
            rewrite_with_rules("git commit -m \"unclosed", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
    }

    #[test]
    fn empty_rules_table_yields_passthrough() {
        // Phase 2 invariant: with no rules populated, every input
        // passes through unchanged.
        assert_eq!(
            rewrite_with_rules("git status", &[], &cfg_empty()),
            Decision::Passthrough
        );
        assert_eq!(
            rewrite_with_rules("cargo test", &[], &cfg_empty()),
            Decision::Passthrough
        );
    }

    #[test]
    fn pipeline_passes_through() {
        // The whole point of the operator check: don't break pipelines.
        assert_eq!(
            rewrite_with_rules("git status -s | head -80", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
        assert_eq!(
            rewrite_with_rules(
                "git ls-files | grep -E 'bench|perf'",
                TEST_RULES,
                &cfg_empty()
            ),
            Decision::Passthrough
        );
    }

    #[test]
    fn redirection_passes_through() {
        assert_eq!(
            rewrite_with_rules("cat /etc/hosts > /tmp/h", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
        assert_eq!(
            rewrite_with_rules(
                "git diff 2>/dev/null > /tmp/d",
                TEST_RULES,
                &cfg_empty()
            ),
            Decision::Passthrough
        );
    }

    #[test]
    fn logical_operators_pass_through() {
        assert_eq!(
            rewrite_with_rules("git status && git push", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
        assert_eq!(
            rewrite_with_rules("git status || true", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
        assert_eq!(
            rewrite_with_rules("git status; git diff", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
    }

    #[test]
    fn command_substitution_passes_through() {
        assert_eq!(
            rewrite_with_rules("cat $(which bash)", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
        assert_eq!(
            rewrite_with_rules("cat `which bash`", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
        assert_eq!(
            rewrite_with_rules("(git status)", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
    }

    #[test]
    fn quoted_operators_do_not_trigger() {
        // The `|` is inside single quotes, so the operator scan sees it
        // as part of a quoted region and does not bail out. The exact
        // re-quoting style is up to shell_words::join — it wraps the
        // whole token containing a metacharacter in single quotes, which
        // bash parses identically to the input.
        match rewrite_with_rules("git log --grep='foo|bar'", TEST_RULES, &cfg_empty()) {
            Decision::Rewrite(s) => {
                assert!(
                    s.starts_with("pi-rs git log "),
                    "expected pi-rs git log rewrite, got: {s}"
                );
                assert!(
                    s.contains("foo|bar"),
                    "expected the quoted pipe to survive in: {s}"
                );
            }
            other => panic!("expected Rewrite, got {other:?}"),
        }
    }

    #[test]
    fn argv_predicate_can_force_passthrough() {
        // The `ls` test rule has `argv_compatible: Some(never_ok)`,
        // so any `ls …` invocation passes through.
        assert_eq!(
            rewrite_with_rules("ls", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
        assert_eq!(
            rewrite_with_rules("ls -la /tmp", TEST_RULES, &cfg_empty()),
            Decision::Passthrough
        );
    }

    #[test]
    fn basename_handles_no_slashes() {
        assert_eq!(basename("git"), "git");
    }

    #[test]
    fn basename_strips_leading_path() {
        assert_eq!(basename("/usr/bin/git"), "git");
        assert_eq!(basename("./scripts/foo.sh"), "foo.sh");
    }

    #[test]
    fn basename_empty_string() {
        assert_eq!(basename(""), "");
    }

    #[test]
    fn contains_shell_operator_basics() {
        assert!(!contains_shell_operator("git status"));
        assert!(!contains_shell_operator("rg --pattern foo --path src"));
        assert!(contains_shell_operator("a | b"));
        assert!(contains_shell_operator("a||b"));
        assert!(contains_shell_operator("a&&b"));
        assert!(contains_shell_operator("a;b"));
        assert!(contains_shell_operator("a & b"));
        assert!(contains_shell_operator("a > b"));
        assert!(contains_shell_operator("a < b"));
        assert!(contains_shell_operator("a >> b"));
        assert!(contains_shell_operator("a 2>/dev/null"));
        assert!(contains_shell_operator("a `b`"));
        assert!(contains_shell_operator("a $(b)"));
        assert!(contains_shell_operator("(a)"));
    }

    #[test]
    fn contains_shell_operator_respects_quotes() {
        assert!(!contains_shell_operator("grep 'a|b' file"));
        assert!(!contains_shell_operator("grep \"a|b\" file"));
        assert!(!contains_shell_operator("grep 'a;b' file"));
        // Double quotes do allow command substitution.
        assert!(contains_shell_operator("echo \"$(date)\""));
        assert!(contains_shell_operator("echo \"`date`\""));
        // Escaped operator is not an operator.
        assert!(!contains_shell_operator("printf 'a\\|b'"));
    }
}
