---
name: repo-sync
description: Inspect or synchronize a Git worktree with its configured upstream using the deterministic repo-sync command. Use for routine pull, push, or repository sync requests; resolve divergence and other exceptions within the existing task scope.
---

# Repo sync

Use `repo-sync` for the mechanical work. Routine synchronization needs no new
model, worker, or coordinator. Keep the user's repository, direction, and existing
authorization; a pull request does not authorize a push. Read applicable `AGENTS.md`
checks and pass their actual command argv. The command does not infer required checks.

```sh
repo-sync --repo /path/to/checkout --direction both
repo-sync --repo /path/to/checkout --direction both --apply \
  --check '["python3", "-m", "unittest"]'
```

The default fetches the selected upstream branch and produces a plan. It may
update its remote-tracking ref, but leaves the local branch, index, and worktree
alone and never pushes. `--apply` performs already-authorized actions; do not ask
again for a push the user has authorized. Choose `pull`, `push`, or `both` (default).
Repeat `--check JSON_ARGV` for checks; they run in the worktree root without a
shell, on apply, after any fast-forward and before any push. `--timeout SECONDS`
bounds each subprocess (default 60). Set it high enough for the required checks.
On failure, check stdout/stderr and Git diagnostics are saved in private logs
outside the worktree (a 0700 `/tmp/repo-sync-*` directory with 0600 log files).
JSON contains log paths, never raw command output or remote URLs. Read the
reported `log` file to investigate without rerunning an expensive failed check.
Treat logs as potentially sensitive and remove their directory when no longer needed.

Read the single JSON object on stdout, including on errors:

- Exit **0**: `planned` or `synced`. `synced` means the requested direction
  completed. Pull-only may leave local commits ahead; inspect `converged`,
  `ahead`, and `behind` before claiming full convergence.
- Exit **2**: `needs_decision`, with a stable `reason` and `next_action`.
  Dirty files, active Git operations, divergence, unsupported upstream mappings,
  state changes, and another repo-sync holding the lock stop automation.
- Exit **1**: `failed`, including invalid arguments, failed checks, network
  failures, and timeouts. Ordinary `--help` prints help and exits 0.

Schema version 1 includes canonical `repo`, `branch`, `upstream` (remote name and full branch ref),
`before`/`after` local and remote OIDs, final ahead/behind counts when known,
`remote_verified`, `clean`, ordered completed `actions`, `planned_actions`, check
outcomes, bounded `diagnostics`, and `next_action`. Remote OIDs are observations,
not a guarantee against future changes. `checks.status=not_requested` means no
checks were supplied, never that checks passed. Plans report supplied checks as
`not_run`; `incomplete` means execution stopped before all supplied checks ran.
Check records use zero-based indexes in supplied order.

Keep partial progress: a fast-forward can complete before a check fails. Never
roll it back, create commits, stash, reset, rebase, merge divergent histories,
change upstream/config, bypass hooks/signing, or force push as part of routine
sync. After an interrupted/failed push, inspect `after.remote` and
`remote_verified`; verify uncertain remote state before deciding whether another
push is appropriate. Do not blindly retry.

The command accepts one upstream branch with a conventional remote-tracking
mapping, matching single fetch/push URLs, and ordinary Git transports or local
remote paths. Shallow history and ambiguous/custom mappings require a separate
decision. Its advisory common-directory lock serializes repo-sync across linked
worktrees; it cannot lock out humans or other Git tools. It rechecks state and
pushes the checked commit OID, but Git and remote state can still change after a
check. No rollback or atomic transaction across a network is promised.

When chief-of-staff is already active, return the command result to that
coordinator. Hydrogen may interpret the bounded JSON or summarize an exception
when available and authorized; it is optional and does not replace the command.
Use a model only for an exception that requires judgment, preserve task scope,
and stop for a user decision when the needed action is outside that scope.
