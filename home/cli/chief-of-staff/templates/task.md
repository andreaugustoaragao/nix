# <task ID>: <goal>

- State: queued
- Previous stage (when blocked/paused): <stage or not applicable>
- Original user request / delivery reference: <literal request and identifier if available>
- Priority / ordering reason: FIFO unless the user specifies otherwise
- Dependencies: <task IDs or none>
- Repository / original checkout: <absolute path>
- Integration target: <coordinator-owned checkout/branch, or not applicable>
- Allowed scope / exclusions: <paths and boundaries>
- Deliverable: <concrete outcome>
- Acceptance checks: <required evidence>
- Next action / unblock condition: <specific action>

## Baseline and isolation

Record initial Git status including staged, unstaged and untracked work; commit
ID; task-relevant uncommitted changes and their isolated carry-forward; branch
and worktree paths; shared-resource constraints; worker baseline confirmation.

## Assignments and launch intents

For each worker: unique name, role, harness, subscription/provider route, exact
model/effort, objective, absolute cwd,
allowed scope, context, exclusions, deliverable, checks and literal coordinator
terminal address. Record intent BEFORE launch, then returned ID, owning core,
startup/model evidence, session resume ID, tab/split, and whether the first message was sent. Unknown outcomes
require reconciliation, not a duplicate launch.

For each assignment, record required tools and one routing reason or override.
Keep provider separate from harness; record observed failure before using a
fallback. For GUI/UI/UX, record the Google review model and chosen stage
(design or rendered artifact), with evidence in the section below.

## Reports and evidence

Reference implementation artifacts, actual changes, check commands/results,
independent review findings and accepted fixes. Keep worker reports separate
from coordinator acceptance. Secrets must remain outside these records.

When available, record total reported API cost including retries/auxiliary calls,
input/cache-read/cache-write/output tokens, and rework or escalation. Missing
cost is unknown. Keep actual subscription allowance/credit consumption separate
from API dollars. Include observed resource constraints when they affected the
choice; do not infer them from a single cache-hit percentage or idle sample.

## Integration and verification

Record target recheck, baseline drift/conflict assessment, integration method,
affected post-integration checks and practical limitations. Mark done only when
the requested deliverable and required acceptance gates have passed.

## Blockers, pause or cancellation

Record the previous stage, decision needed, live workers and retained partial
changes. Capture artifacts before stopping task-owned workers. Cancellation is
complete only after stopping is confirmed; flag dependent tasks explicitly.

## Cleanup and next steps

Record closed worker IDs, removed worktrees/branches, intentionally retained resources, artifact/worktree
paths, remaining limitations and next action. Never discard unintegrated work.
