//! Static rewrite rules table.
//!
//! Each [`Rule`] maps an `argv[0]` basename to the pi-rs subcommand that
//! handles it. Lookups are by basename only (`/usr/bin/git` and `git` both
//! resolve to the `git` rule); `argv[1..]` is only inspected when the rule
//! supplies an [`Rule::argv_compatible`] predicate.
//!
//! Wrappers are responsible for falling back to passthrough internally when
//! they see an arg shape they can't compress — the oracle's job is just to
//! decide *which binary owns this command class*. The exception is the set
//! of "primitive" rewrites (`ls`, `find`, `rg`, `cat`, `jq`) whose pi-rs
//! grammars are deliberately narrow; for those the oracle declines the
//! rewrite via `argv_compatible` instead of letting the wrapper bail with a
//! clap error message the user never asked for.
//!
//! Populated incrementally by phase-4+ wrapper PRs.

// PartialEq/Eq are intentionally not derived: function-pointer equality
// is well-defined at the language level but Rust warns about it because
// different codegen units can host the same function at different
// addresses. Nothing in the oracle compares `Rule`s for equality.
#[derive(Debug, Clone, Copy)]
pub struct Rule {
    /// `argv[0]` basename to match (e.g., "git", "cargo", "cat").
    pub bin: &'static str,
    /// pi-rs subcommand to dispatch to (e.g., "git", "cargo", "read").
    /// In most cases `subcmd == bin`; differs when we remap (cat→read).
    pub subcmd: &'static str,
    /// Optional argv-shape predicate. Receives `argv[1..]` (the bin name
    /// already stripped). If `Some(pred)` and `pred(args) == false`, the
    /// oracle treats the command as passthrough — so the original tool
    /// keeps running with its native flag set.
    ///
    /// Wrappers whose CLI is a superset of the original tool's (`git`,
    /// `cargo`, `gh`, `npm`, `pnpm`, `yarn`, `pytest`, `docker`,
    /// `kubectl`) leave this `None`: they handle every invocation,
    /// either by routing to a known subcommand or via clap's
    /// `external_subcommand` passthrough inside the wrapper itself.
    pub argv_compatible: Option<fn(&[String]) -> bool>,
}

/// Live rewrite rules.
///
/// Order is irrelevant (lookup is `iter().find()` on `bin`). When you add
/// a rule here, also add a `cmd::filters::<subcmd>` module and a
/// clap-subcommand variant in `main.rs`.
pub static RULES: &[Rule] = &[
    // External-tool wrappers. These accept anything (clap external
    // subcommand passthrough or trailing-var-arg) so no argv predicate
    // is needed.
    Rule {
        bin: "git",
        subcmd: "git",
        argv_compatible: None,
    },
    Rule {
        bin: "cargo",
        subcmd: "cargo",
        argv_compatible: None,
    },
    Rule {
        bin: "gh",
        subcmd: "gh",
        argv_compatible: None,
    },
    Rule {
        bin: "npm",
        subcmd: "npm",
        argv_compatible: None,
    },
    Rule {
        bin: "pnpm",
        subcmd: "pnpm",
        argv_compatible: None,
    },
    Rule {
        bin: "yarn",
        subcmd: "yarn",
        argv_compatible: None,
    },
    Rule {
        bin: "pytest",
        subcmd: "pytest",
        argv_compatible: None,
    },
    Rule {
        bin: "docker",
        subcmd: "docker",
        argv_compatible: None,
    },
    Rule {
        bin: "kubectl",
        subcmd: "kubectl",
        argv_compatible: None,
    },
    // Primitive remaps. `pi-rs ls / find / grep / read / json` each have
    // a CLI that is *narrower* than the tool they shadow, so the oracle
    // must refuse to auto-rewrite anything outside that grammar — otherwise
    // ordinary commands like `ls -la`, `find . -maxdepth 3 -type f`, or
    // `rg -n 'foo' src/` would fail with a confusing clap error instead of
    // running the real tool.
    Rule {
        bin: "cat",
        subcmd: "read",
        argv_compatible: Some(cat_argv_ok),
    },
    Rule {
        bin: "rg",
        subcmd: "grep",
        argv_compatible: Some(rg_argv_ok),
    },
    Rule {
        bin: "ls",
        subcmd: "ls",
        argv_compatible: Some(ls_argv_ok),
    },
    Rule {
        bin: "find",
        subcmd: "find",
        argv_compatible: Some(find_argv_ok),
    },
    Rule {
        bin: "jq",
        subcmd: "json",
        argv_compatible: Some(jq_argv_ok),
    },
];

/// `pi-rs ls` accepts at most one positional path and only `-a`/`--all`
/// (or its clustered short form). Anything else — `-l`, `-la`, `--color`,
/// extra paths, etc. — passes through to the real `ls`.
fn ls_argv_ok(args: &[String]) -> bool {
    let mut positional = 0_usize;
    for a in args {
        if let Some(rest) = a.strip_prefix("--") {
            let flag = rest.split('=').next().unwrap_or(rest);
            if !matches!(flag, "all") {
                return false;
            }
        } else if let Some(rest) = a.strip_prefix('-') {
            if rest.is_empty() {
                // Bare `-` is treated as a path by ls; pi-rs ls doesn't
                // accept it, so passthrough.
                return false;
            }
            // Short-flag cluster — only `-a` allowed.
            if !rest.chars().all(|c| c == 'a') {
                return false;
            }
        } else {
            positional += 1;
            if positional > 1 {
                return false;
            }
        }
    }
    true
}

/// Native find paths/actions and ripgrep's -p (pretty) option do not map
/// to the pi-rs primitives. Only explicit pi-rs invocations use those CLIs.
fn find_argv_ok(_args: &[String]) -> bool {
    false
}

fn rg_argv_ok(_args: &[String]) -> bool {
    false
}

/// Only a single native cat path has the same argument meaning in pi-rs.
fn cat_argv_ok(args: &[String]) -> bool {
    args.len() == 1 && !args[0].starts_with('-')
}

/// `pi-rs json` has a selection/viewer CLI distinct from jq's filter language.
/// Disable the auto-rewrite entirely — explicit `pi-rs json …` still
/// works.
fn jq_argv_ok(_args: &[String]) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn ls_allows_bare_and_dash_a() {
        assert!(ls_argv_ok(&v(&[])));
        assert!(ls_argv_ok(&v(&["-a"])));
        assert!(ls_argv_ok(&v(&["--all"])));
        assert!(ls_argv_ok(&v(&["/tmp"])));
        assert!(ls_argv_ok(&v(&["-a", "/tmp"])));
    }

    #[test]
    fn ls_rejects_unknown_flags() {
        assert!(!ls_argv_ok(&v(&["-l"])));
        assert!(!ls_argv_ok(&v(&["-la"])));
        assert!(!ls_argv_ok(&v(&["-l", "-a"])));
        assert!(!ls_argv_ok(&v(&["--color"])));
    }

    #[test]
    fn ls_rejects_multiple_positionals() {
        assert!(!ls_argv_ok(&v(&["/tmp", "/etc"])));
    }

    #[test]
    fn find_never_reinterprets_native_paths_as_patterns() {
        assert!(!find_argv_ok(&v(&["*.rs"])));
        assert!(!find_argv_ok(&v(&["Cargo.toml", "."])));
        assert!(!find_argv_ok(&v(&["--limit", "10", "*.rs"])));
        assert!(!find_argv_ok(&v(&["--limit=10", "*.rs"])));
    }

    #[test]
    fn find_rejects_gnu_actions() {
        assert!(!find_argv_ok(&v(&[".", "-maxdepth", "3"])));
        assert!(!find_argv_ok(&v(&[".", "-type", "f"])));
        assert!(!find_argv_ok(&v(&["-name", "*.rs", "."])));
        assert!(!find_argv_ok(&v(&[".", "-printf", "%p\\n"])));
        assert!(!find_argv_ok(&v(&[".", "-print0"])));
    }

    #[test]
    fn rg_never_reinterprets_pretty_as_a_path_flag() {
        assert!(!rg_argv_ok(&v(&["-e", "foo", "-p", "src"])));
        assert!(!rg_argv_ok(&v(&["--pattern", "foo", "--path", "src"])));
        assert!(!rg_argv_ok(&v(&["--pattern=foo", "--path=src"])));
        assert!(!rg_argv_ok(&v(&[
            "-e",
            "foo",
            "-p",
            "src",
            "-i",
            "--context-after",
            "5",
        ])));
    }

    #[test]
    fn rg_rejects_gnu_shape() {
        // bare positionals: rg PATTERN PATH
        assert!(!rg_argv_ok(&v(&["foo", "src"])));
        // -n / -E / -S — common ripgrep flags pi-rs grep doesn't know
        assert!(!rg_argv_ok(&v(&["-n", "-e", "foo", "-p", "src"])));
        assert!(!rg_argv_ok(&v(&["-E", "foo", "src"])));
        assert!(!rg_argv_ok(&v(&["-S", "-e", "foo", "-p", "src"])));
        // missing --pattern or --path
        assert!(!rg_argv_ok(&v(&["-e", "foo"])));
        assert!(!rg_argv_ok(&v(&["-p", "src"])));
    }

    #[test]
    fn cat_accepts_single_path() {
        assert!(cat_argv_ok(&v(&["/etc/passwd"])));
        assert!(!cat_argv_ok(&v(&["-l", "signature", "src/main.rs"])));
        assert!(!cat_argv_ok(&v(&["--level=raw", "src/main.rs"])));
    }

    #[test]
    fn cat_rejects_flags_and_multifile() {
        assert!(!cat_argv_ok(&v(&["-A", "/etc/passwd"])));
        assert!(!cat_argv_ok(&v(&["-n", "/etc/passwd"])));
        assert!(!cat_argv_ok(&v(&["/etc/passwd", "/etc/hosts"])));
        assert!(!cat_argv_ok(&v(&[])));
    }

    #[test]
    fn jq_never_rewrites() {
        assert!(!jq_argv_ok(&v(&[])));
        assert!(!jq_argv_ok(&v(&[".foo"])));
        assert!(!jq_argv_ok(&v(&["-r", ".foo"])));
    }
}
