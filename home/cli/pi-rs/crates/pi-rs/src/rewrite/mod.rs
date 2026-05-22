//! Rewrite oracle: maps shell commands to their pi-rs-compressed equivalents.
//!
//! Consumed by `pi-rs rewrite "<cmd>"` (the agent-facing API) and by
//! `pi-rs hook claude|cursor` (the protocol-specific adapters). Per-agent
//! shim scripts and the pi TS extension all funnel through the same
//! [`rewrite()`] function.
//!
//! Behavior (aggressive policy):
//!
//! 1. Tokenize the command string via [`shell_words::split`]. Malformed
//!    quoting → [`Decision::Passthrough`] (never crash a hook on bad input).
//! 2. Take the basename of `argv[0]`. `/usr/bin/git` and `git` resolve the
//!    same way.
//! 3. If the basename is in [`config::Config::exclude`], passthrough.
//! 4. Look up the basename in [`rules::RULES`]. If no entry, passthrough.
//! 5. Otherwise: replace `argv[0]` with `pi-rs <rule.subcmd>` and re-emit
//!    via [`shell_words::join`] (which re-quotes args containing spaces).
//!
//! Wrappers themselves decide whether they can actually compress a specific
//! invocation. The oracle doesn't look at `argv[1..]`; if a wrapper sees an
//! arg shape it doesn't know, it falls through to running the real command
//! and applying [`crate::compress::tee`].

pub mod config;
pub mod rules;

use config::Config;
use rules::{Rule, RULES};

/// Outcome of a rewrite lookup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// No rule matched, argv[0] was excluded, or tokenization failed.
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

    const TEST_RULES: &[Rule] = &[
        Rule {
            bin: "git",
            subcmd: "git",
        },
        Rule {
            bin: "cat",
            subcmd: "read",
        },
    ];

    #[test]
    fn empty_input_passes_through() {
        assert_eq!(rewrite_with_rules("", TEST_RULES, &cfg_empty()), Decision::Passthrough);
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
}
