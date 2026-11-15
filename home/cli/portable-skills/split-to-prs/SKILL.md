---
name: split-to-prs
description: Split requested work into small reviewable Git branches or pull requests while preserving committed, staged, unstaged, and untracked user work.
---

# Split work into reviewable changes

Inspect the actual base, branch commits, staged/unstaged changes, untracked files, and ownership boundaries. Identify cohesive slices and real dependencies. Prefer independent branches; stack only where a dependency requires it. Use a compact task table when several slices depend on one another.

Proceed with branch/commit work already authorized by the split request. Ask only about material scope or destination ambiguity. Push and open PRs only when authorized and the required provider tool is available; otherwise prepare reviewable local branches and report their state.

Preserve the starting checkout. Before moving any uncommitted work, make a private recoverable snapshot with a manifest of committed base, staged diff, unstaged diff, and every intended untracked file. Use binary patches/byte copies as needed. A stash-created commit alone excludes untracked files and is not a complete backup. Verify snapshot contents before relying on it; keep secrets out of reports.

Build each slice in an isolated worktree from the correct base. Stage only its named files/hunks, include relevant tests, and verify its behavior and dependent slices. Do not stash/reset the user's checkout, force push, rewrite history, delete original work, or overwrite another agent's files.

Report branch/commit or real PR URLs, validation, preserved snapshot location, and work not included in a slice. Review readiness does not mean merged or deployed.
