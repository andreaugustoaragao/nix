---
name: herdr-coordinate
description: Coordinate a development task with Codex, Grok 4.7 workers in Cursor Agent, and independent Codex review through Herdr. Use when explicitly asked for Herdr coordination or this development mode.
---

# Herdr development mode

Invoke with `$herdr-coordinate <task>`. The current Codex conversation is the
coordinator for this task and its follow-ups. Own requirements, decomposition,
integration and verification. Invocation authorizes the bounded worker workflow
below; it does not change the behavior of unrelated tasks or permission policies.

## Prepare

Read the installed `herdr-core` skill and run `agent-host-context`, `hc --skill`,
and `hc templates`. For Desktop visibility, consult `herdr-app --skill` and
`herdr-app status`. Preserve the current layout, focus and unrelated terminals.
Require the intended `HC_TERMINAL_ID` and owning core; don't choose an unrelated
default core when the coordinator has no terminal context.

Check `cursor-agent models` and the installed Codex configuration/model catalog.
Use these exact model choices:

| Launch | Model | Use |
| --- | --- | --- |
| `herdr-cursor MODEL TASK` | Cursor `grok-4.7-high` | Default implementation |
| `herdr-cursor MODEL TASK` | Cursor `grok-4.7-xhigh` | Particularly difficult work |
| `herdr-cursor MODEL TASK` | Cursor `composer-2.5` | Small, mechanical work when requested |
| `dev-review` | Codex `gpt-6-astra`, `xhigh` | Fresh, independent review |

Verify the actual model at startup. A listed Cursor model does not prove that
the account permits every effort/speed setting. Stop the affected assignment
and explain any rejected model or authentication requirement; never silently
substitute Auto, another model, or another effort level. Keep worker permission
settings intact. This mode does not enable Run Everything or disable sandboxes.

Start with one implementer. Add a second only for independent work. Keep at most
three workers open at once, including the reviewer, and obey any smaller session
limit. Workers must not delegate. Use Herdr terminals for this workflow; Codex's
native subagent threads do not automatically appear in the Herdr dashboard.
Other skills may provide technical guidance without starting a second agent tree.

## Own the work and its record

Inspect Git status, including staged and untracked work, before assigning edits.
Give each writer a separate worktree and branch; read-only workers may share a
checkout. A worktree starts from a commit, so explicitly carry any task-relevant
uncommitted changes into an isolated baseline without committing, stashing or
resetting the user's checkout. Confirm the worker sees the intended baseline.

Keep one coordinator-owned record outside the worktrees, under
`${XDG_STATE_HOME:-$HOME/.local/state}/herdr-coordinate/<task-id>/`.
Record the goal, acceptance checks, original checkout and baseline, terminal
IDs, branches/worktrees, assignments, chosen models, decisions, reports and next
steps. Workers report to the coordinator instead of concurrently editing this
record. On resuming a conversation, reconcile the record against Git and `hc get`
before starting or repeating work. An idle/done agent is not a verified task.

Each assignment needs: a concrete objective, absolute working directory, allowed
files/scope, necessary context, exclusions, a deliverable, completion checks,
and the coordinator's literal terminal address. Pass reports as concise findings
with artifact paths, not entire transcripts. Use Graphify where supported and
LSP/current source to ground work; follow project verification requirements.

## Dispatch and follow up

Replace the example paths, name and coordinator address before running:

```sh
hc run --bg --name task-impl --cwd /absolute/worktree -- herdr-cursor grok-4.7-high \
  "Implement <objective>. Scope: <files>. Verify: <checks>. Report to t8 with hc send t8 when done or blocked. No subagents."
```

The launcher supplies the worker instructions and assignment as Cursor's initial
prompt argument. Cursor retains that prompt through its startup/trust flow; core
does not paste it into a possibly quiet dialog. Read the startup screen and
observed model. Never blindly resend a task after an uncertain launch. Resolve
only trust decisions already authorized by the task; surface new permission or
login decisions to the user.

`herdr-cursor` loads a session-local Cursor plugin that reports `working` on
prompt submission and `done`, `idle` or `error` when the turn ends. It does not
change global Cursor hooks. It cannot detect every permission/trust dialog;
inspect the screen when a wait times out. Workers can explicitly report a
question with `herdr-cursor-status blocked question`. That marker survives the
turn ending and clears when the next prompt is accepted.

Use `hc wait --children any --timeout 30` while awaiting results, doing useful
independent work between waits. Messages arrive as input. After a report, read
the actual output/artifacts; `hc wait` returns status, not the answer. Read a
worker before retrying a failed send. A reported question blocks normal sends:
check `hc get` shows `kind: question`, read the question and verify that Cursor
is at its ordinary input prompt. Then `hc send --force` may deliver the answer
to that question. Never force-send into a permission, authentication or trust
dialog. Send corrections to the same worker conversation:

```sh
hc send --wait --timeout 30 task-impl "Fix <specific finding>; rerun <affected check>."
hc read task-impl --lines 80
```

Children started from this coordinator inherit its Desktop tab. Use `hc get`
and `herdr-app ls` to confirm visibility; use the documented space/tab labels
only if adoption is needed. Don't switch Board/Mission or rearrange existing
work to make the workflow operate.

## Review, integrate and finish

After implementation, start a fresh read-only session against the worker's
actual checkout:

```sh
hc run --bg --name task-review --cwd /absolute/worktree dev-review \
  "<review assignment and coordinator address>"
```

Supply the original requirements, baseline/diff,
acceptance criteria and verification evidence, without the implementer's
self-assessment. The managed `codex` launcher already adds `--no-daemon` inside
Herdr; do not add that flag a second time.
Check the review launch's `first_message.sent`; if false, inspect the screen and
resolve startup before sending its role instructions and assignment once.

Require reproducible defects with file/line evidence and practical impact.
Don't use an arbitrary numerical cutoff to dismiss defects. Keep unrelated
pre-existing issues separate, and avoid stylistic churn. Send accepted fixes
back to the original implementer. Review again only for changed behavior,
unresolved findings or missing coverage; reuse valid evidence.

Integrate through one coordinator-owned checkout, preserving unrelated work.
Inspect the actual changes and run the relevant checks after integration.
For UI work, inspect the real app using the project's browser workflow or
Herdr's native screenshot commands. Record what passed and any remaining limits.

After accepting the result, kill/remove only workers created for this task.
Keep worktrees with unintegrated changes and preserve the task record and
reports. Never stop/restart core as cleanup. Report the result, verification,
remaining work and any resources intentionally left running. The mode ends
with the task, or when the user asks to return to direct work.
