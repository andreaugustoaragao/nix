//! Static rewrite rules table.
//!
//! Each [`Rule`] maps an `argv[0]` basename to the pi-rs subcommand that
//! handles it. Lookups are by basename only (`/usr/bin/git` and `git` both
//! resolve to the `git` rule); `argv[1..]` is not inspected.
//!
//! Wrappers are responsible for falling back to passthrough internally when
//! they see an arg shape they can't compress — the oracle's job is just to
//! decide *which binary owns this command class*.
//!
//! Populated incrementally by phase-4+ wrapper PRs.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rule {
    /// `argv[0]` basename to match (e.g., "git", "cargo", "cat").
    pub bin: &'static str,
    /// pi-rs subcommand to dispatch to (e.g., "git", "cargo", "read").
    /// In most cases `subcmd == bin`; differs when we remap (cat→read).
    pub subcmd: &'static str,
}

/// Live rewrite rules.
///
/// Order is irrelevant (lookup is `iter().find()` on `bin`). When you add
/// a rule here, also add a `cmd::filters::<subcmd>` module and a
/// clap-subcommand variant in `main.rs`.
pub static RULES: &[Rule] = &[
    // External-tool wrappers.
    Rule { bin: "git", subcmd: "git" },
    Rule { bin: "cargo", subcmd: "cargo" },
    Rule { bin: "gh", subcmd: "gh" },
    Rule { bin: "npm", subcmd: "npm" },
    Rule { bin: "pnpm", subcmd: "pnpm" },
    Rule { bin: "yarn", subcmd: "yarn" },
    Rule { bin: "pytest", subcmd: "pytest" },
    Rule { bin: "docker", subcmd: "docker" },
    Rule { bin: "kubectl", subcmd: "kubectl" },

    // Primitives the LLM commonly invokes. `cat` and `rg` remap to
    // pi-rs's own primitives; the others are direct wrappers.
    Rule { bin: "cat", subcmd: "read" },
    Rule { bin: "rg", subcmd: "grep" },
    Rule { bin: "ls", subcmd: "ls" },
    Rule { bin: "find", subcmd: "find" },
    Rule { bin: "jq", subcmd: "json" },
];
