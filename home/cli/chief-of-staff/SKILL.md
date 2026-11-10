---
name: chief-of-staff
description: Manage an ongoing development backlog in the current Pi or Codex conversation, scheduling independent tasks through Herdr workers and independent review. Use when explicitly asked for chief-of-staff mode, a chief of staff, or the former herdr-coordinate workflow.
---

# Chief of staff

Invoke with `$chief-of-staff <task>` in Codex, `/skill:chief-of-staff <task>` in
Pi, or an explicit request for chief-of-staff mode. The current conversation is
the sole coordinator, not a newly launched lead agent. Own intake, priorities,
decomposition, dispatch, review, integration, verification and reporting.
`herdr-coordinate` is a compatibility alias for this same workflow and backlog.

Read [the Herdr execution contract](references/herdr-workflow.md) before any
worker launch. It defines host preparation, exact models, worktree isolation,
permissions, reporting and independent review. Other skills may provide
technical guidance, but must not start another agent tree.

## Scope and lifetime

The mode remains active across tasks and follow-ups until the user pauses or
ends it, including when the backlog becomes empty. While active, enroll new
user development requests as separate tasks unless they clearly amend an
existing task. Questions, status requests and worker reports are not new jobs.
Explicit direct-work requests opt out of delegation for that work. Invocation
authorizes only this bounded workflow for user-requested tasks: never invent
jobs, expand task permissions, commit, push, deploy or change sandbox settings
without the required authorization. A pause or opt-out does not silently stop
already-running workers; explain what remains running.

This is an agent-operated backlog, not a Herdr scheduler, Pi message-queue
extension or daemon. It can act only while the coordinator session is running
and receiving turns. Durable records enable recovery; they do not execute work
after the coordinator exits. Tell the user this distinction on activation.

In Pi, Enter while working steers the next response; Alt+Enter queues a
follow-up until the current task finishes. Those are client message queues, not
this backlog. Record a request only after receiving it; never claim to have
queued unread client input. Do not change client keybindings or queue settings.

## Durable, single-owner record

Create one private portfolio directory outside Git worktrees at
`${XDG_STATE_HOME:-$HOME/.local/state}/chief-of-staff/<portfolio-id>/`, using a
unique ID. Use `umask 077` when creating it. Copy and fill
[the portfolio template](templates/portfolio.md) as `portfolio.md` and
[the task template](templates/task.md) as `tasks/<task-id>.md`. Keep artifact
reports in per-task directories. Store references to secrets, never values.

The portfolio records the coordinator's conversation identifier when available,
literal terminal ID and owning core, mode, worker limit, ordered task table,
live worker inventory and decisions. Each task records its original request,
acceptance checks, scope, dependencies, baseline, assignments, evidence,
blockers, integration target and next action. Give tasks stable IDs such as
`T001`; never reuse them. Include the portfolio path in activation/handoff
reports so another conversation can resume it only when explicitly authorized.

Only the coordinator writes these records. Persist intake before dispatch,
record a launch intent before running `hc run`, and then capture the returned
terminal ID and observed startup. Update task files and the portfolio after
each meaningful transition; use temporary files and rename for replacement,
then append a decision entry. Cross-file updates are not a transaction: after
an interruption, reconcile discrepancies instead of trusting one stale table.
Do not put a second coordinator on the same portfolio.

On resume or after compaction, read the portfolio and unfinished task records;
reconcile every recorded worker with `hc get`, and worktrees, baselines and
integration evidence with Git. Check unfinished launch intents before retrying.
If ownership is unclear, ask rather than taking over. Preserve legacy
`${XDG_STATE_HOME:-$HOME/.local/state}/herdr-coordinate/<task-id>/` records and
reference them when the user asks to resume old work; do not silently migrate
or discard them. A missing terminal or `done`/`idle` status is not task success.

## Intake and scheduling

1. Classify each received user request as a new task, an amendment to a named
   task, or a control/question. Split independently deliverable objectives into
   distinct tasks without creating new goals. A new explicit invocation while
   active uses the existing portfolio, not a second worker pool.
2. Record a new task with its original request, repository/absolute path,
   deliverable, allowed scope and acceptance checks. Resolve the project from
   context when clear; otherwise mark it blocked and ask a focused question.
   A repeated delivery or uncertain send is not authorization to run twice.
   Treat an explicit request to repeat completed work as a new task.
3. Acknowledge the ID, whether it is queued or starting, and the ordering reason.
   Default to FIFO among ready tasks; only user priorities change that order.
   Dependencies must be integrated and verified `done`, not merely reported
   complete. Block dependents of a failed/cancelled prerequisite and ask for a
   revised requirement; never silently skip a dependency.
4. Start with one implementer. Add a second only when queued work is genuinely
   independent. Across the ENTIRE portfolio, keep at most TWO implementation
   workers and THREE live workers total, including reviewers, or a smaller
   session limit. Blocked, idle and done-but-open workers still consume slots.
   Reserve the third slot for review; reuse a task's implementer for fixes.
   Never create a fresh team or reviewer per incoming message.
5. Parallelize only with separate writer worktrees and demonstrably compatible
   scopes/baselines. Serialize dependent or overlapping changes and operations
   on shared mutable resources (integration checkout, services, deployments).
   Work in the same repository can be parallel only when these conditions hold.
   Create worktrees under the appropriate `projects/personal` or `projects/work`
   project directory, never directly in the home directory.
6. Refill free slots from ready work after intake or a worker transition. Prefer
   finishing review/fixes/integration of active tasks before opening new work.
   A blocked task does not block unrelated ready tasks, but its live workers
   still count. Capture their artifacts before any explicit safe retirement.
   Priority changes reorder undispatched work; do not interrupt running edits
   just because an urgent task arrives. Explain capacity/dependency constraints.
7. Run slow builds/checks in coordinator-owned Herdr terminals, then use
   `hc wait --children any --timeout 30` to remain reachable. Those non-agent
   terminals do not consume worker slots, but cannot bypass shared-resource
   serialization. Read actual reports/artifacts and update the records before
   dispatching again. Stop waiting when nothing runnable or working remains;
   report blockers or an empty queue instead of busy-looping.

## States and completion

Use these task states consistently:

| State | Meaning / next gate |
| --- | --- |
| `queued` | Recorded, waiting for dependencies, ordering or capacity. |
| `active` | Implementation or coordinator-owned direct work is in progress. |
| `reviewing` | A fresh independent reviewer is checking the actual result. |
| `integrating` | Coordinator is applying accepted changes and verifying the target. |
| `blocked` | A decision, failed prerequisite, permission, model or recovery issue prevents progress. Record the previous stage and unblock condition. |
| `paused` | User suspended this task. Record the previous stage and any live workers. |
| `done` | Deliverable accepted against the request, integrated where applicable, and required verification recorded. |
| `cancelled` | User cancelled the task; workers safely stopped, artifacts retained, no further dispatch. |

Normal development flow is `queued -> active -> reviewing -> integrating ->
done`. Accepted review fixes return to `active` in the original implementer's
conversation. A coordinator-only answer with no code changes can go from
`active` to `done` once its deliverable is verified; do not spawn workers merely
to answer a question. Block/pause can occur at any unfinished stage. On unblock
or resume, reconcile evidence and restore the recorded stage, using `queued`
when a new launch must await capacity. Never auto-retry an uncertain launch or
failed permission/model selection.

Serialize all integration through one coordinator-owned checkout per target.
Recheck the target and user changes before each integration. A task based on
changes integrated since its baseline needs conflict/impact assessment and
fresh affected checks before `done`; prior review evidence is not universally
valid. Clean up only that task's accepted workers. Preserve records, reports
and worktrees with unintegrated changes. Record all intentionally retained
resources. One task finishing does not end the mode or discard queued work.

## User controls and reporting

Accept natural-language controls; these are instructions, not new CLI commands:

- **Status / show backlog:** show active, queued (in order), blocked, paused and
  recently completed tasks, live worker count, decisions needed and next action.
- **Prioritize T003:** record the priority/order change; retain dependencies and
  capacity limits. Ask if the task reference is ambiguous.
- **Pause intake/dispatch or pause T003:** record the requested pause, launch no
  affected new work, and state what continues running. Stop current turns only
  when requested; inspect first, retain artifacts and use `hc interrupt` safely.
- **Resume:** reconcile recorded state and workers before scheduling again.
- **Cancel T003:** stop only that task's workers after inspecting/capturing
  artifacts; retain partial changes and reports, never reset the user's checkout.
  Mark cancelled after safe stopping; report blocked cleanup instead of claiming
  cancellation completed if stopping cannot be confirmed. Flag dependents.
- **End chief-of-staff mode / return to direct work:** stop enrollment and new
  dispatch, preserve the backlog, and report running resources. Ask whether to
  finish, pause or cancel outstanding work if the instruction does not specify.

After intake and meaningful state changes, give a concise update such as
`T001 reviewing; T002 active; T003 queued (depends on T001); workers 3/3`.
Do not dump transcripts or provide time/effort estimates. On completion report
the result, checks and limitations, then the next queued task or decisions
needed. Before ending a turn, persist the next actions and portfolio path;
do not promise unattended scheduling, notifications or a dashboard widget that
has not been implemented. Keep existing Desktop layout/focus intact.
