# Herdr execution contract

Follow this contract for every chief-of-staff development task. Portfolio
intake, scheduling and state ownership are defined in the parent SKILL.md.

## Prepare

Run `chief-of-staff-init` once on activation (or `chief-of-staff-init --portfolio <path>`
to resume an explicit portfolio). It checks `HC_TERMINAL_ID` and
`HC_TERMINAL_SOCKET`, enforces the single-coordinator-per-space rule, claims
`herdr.role=chief-of-staff`, renames the current tab to `chief-of-staff`,
creates or reuses the `portfolio.md` record under `umask 077`, and prints
`portfolio_path`, `space`, `tab`, `templates`, `harnesses`, and live space
terminals. Only consult `agent-host-context`, `hc --skill`, `herdr-app --skill`,
`herdr-app status`, or `--help` if `chief-of-staff-init` fails or you hit an
unexpected CLI error. Preserve unrelated layout, focus and terminals. Require
the intended `HC_TERMINAL_ID` and owning core; don't choose an unrelated default
core when the coordinator has no terminal context. Never stop/restart core.

Choose each assignment using [the routing policy](routing.md). Check the selected
harness's current model catalog and launch syntax; reuse verified discovery
within an unchanged environment. Record the exact model, effort, route and
reason, then verify them at startup. For failure, apply only the policy's
authorized fallback and report it; otherwise stop the affected assignment and
explain the rejected model or authentication requirement; never silently
substitute Auto, another model or another effort level. Keep worker permission
settings intact.
This mode does not enable Run Everything or disable sandboxes.

Follow the parent skill's portfolio-wide capacity and the user's requested
Desktop topology. Use Herdr terminals for all workers, and verify their actual
tab/split placement with `herdr-app` when a layout was requested. Multiple
splits may share one tab; do not interpret a tab count as one worker per tab.
Native subagent threads do not automatically appear in Desktop. Workers must
not delegate.

## Naming spaces, tabs, splits, and terminals

Apply these naming and tab-placement rules whenever creating or organizing
Desktop items or `hc` sessions, while preserving unrelated user-named spaces and
tabs:

- **One `chief-of-staff` per space:** every space may have at most one
  `chief-of-staff`, and its tab MUST be named `chief-of-staff`. Check
  `herdr-app ls` and `hc ls --json` before starting; if the current space already
  has another `chief-of-staff` tab or `herdr.role=chief-of-staff` terminal, stop
  and direct the user to it instead of starting a second one. On activation, run
  `hc label "$HC_TERMINAL_ID" herdr.role=chief-of-staff herdr.name=chief-of-staff`
  and `herdr-app do tab.rename --id <your-tab-id> --name chief-of-staff`.
- **Child agents on separate worker tabs (`<= 4` splits per tab):** never place
  worker/child agents inside the `chief-of-staff` tab. Open every child agent on
  another tab in the same space, grouping up to 4 splits per worker tab. Either
  adopt into an existing worker tab with `< 4` panes or open a new named worker
  tab via `--label herdr.space=<space-id> --label herdr.tab=<worker-tab-id>`
  and `herdr-app do tab.rename --id <worker-tab-id> --name "<Topic>"` (avoid
  creating stray empty shell tabs with `tab.new`).
- **Spaces:** `<repo>` for main checkouts; `<repo> · <worktree-or-branch>` for
  linked worktree spaces (for example `vitals · t020-fast-startup`). Disambiguate
  with `· <topic>` when another space already uses `<repo>`.
- **Tabs:** `chief-of-staff` for the coordinator tab; concise task/topic name
  for worker tabs (for example `T020 · Fast startup` or `Vault • proof security`).
- **Terminals & splits:** pass kebab-case `--name <task-id-or-topic>-<role>`
  to every `hc run` (for example `t020-impl`, `t020-review`, `t020-check`,
  `nix-build`). When creating or keeping a Desktop split (`pane.split`,
  `terminal.open`, `terminal.keep`) without `--name`, set
  `hc label <terminal> herdr.name=<role-or-topic>` so `personal-pane` and the
  Agents list display the role clearly.

## Own the work and its record

Inspect Git status, including staged and untracked work, before assigning edits.
Give each writer a separate worktree and branch; read-only workers may share a
checkout. A worktree starts from a commit, so explicitly carry any task-relevant
uncommitted changes into an isolated baseline without committing, stashing or
resetting the user's checkout. Confirm the worker sees the intended baseline.

Use the parent skill's portfolio and per-task records. Persist the goal,
acceptance checks, checkout and baseline, terminal IDs, branches/worktrees,
assignments, models, decisions, reports and next steps. Workers report to the
coordinator instead of concurrently editing those records. Reconcile Git and
`hc get` before starting or repeating work; idle/done is not verified success.

Each assignment needs: a concrete objective, absolute working directory, allowed
files/scope, necessary context, exclusions, a deliverable, completion checks,
and the coordinator's literal terminal address. Pass reports as concise findings
with artifact paths, not entire transcripts. Use Graphify where supported and
LSP/current source to ground work; follow project verification requirements.

## Dispatch and follow up

Prefer `chief-of-staff-spawn --portfolio <portfolio_dir> --goal "<goal>" --role <impl|review|check> --name <kebab-name> --cwd <abs-path> [--tab-name "<Topic>"] [--model <model>] -- <command...>`
to allocate `T00N` / `tasks/T00N.md`, pick or create a worker tab (`<= 4` splits,
never `chief-of-staff`), run `hc run --bg`, rename new tabs, run
`herdr-codex-name` for fresh Codex workers, and update `portfolio.md` in one
command. When launching manually, use a launch command supported by the
selected harness. For the installed Cursor wrapper, replace the example paths,
model, name and coordinator address:

```sh
hc run --bg --name t001-impl --cwd /absolute/worktree -- herdr-cursor gemini-4-carbon-high \
  "Implement <objective>. Scope: <files>. Verify: <checks>. Report to t8 with hc send t8 when done or blocked. No subagents."
```

The Cursor wrapper supplies worker instructions and the assignment as its initial
prompt argument. For Pi or OpenCode, use the current CLI's interactive launch
syntax, include the client-neutral role instructions installed at
`~/.agents/skills/herdr-coordinate/implementer.md` or `reviewer.md`,
and verify `first_message.sent` and the startup screen. Do not use a one-shot
agent mode for an assignment that needs follow-ups. Never blindly resend a task
after an uncertain launch. Resolve only trust decisions already authorized by
the task; surface new permission or login decisions to the user.

### Name Codex workers before their first prompt

Start every new Codex implementer or reviewer without an initial prompt or a
task-bearing template. Wait for startup, check the selected model/provider and
the screen, then run `herdr-codex-name <worker-terminal> <task-id>-<role>`.
The helper sends an explicit `/rename` and waits for a new saved-name record
in Codex's session index. It returns the canonical terminal address, saved
thread name and resume ID. Record those before sending the role instructions
and assignment once with `hc send`.

The helper appends the terminal ID to the task name to distinguish concurrent
workers. If the worker uses a private `CODEX_HOME`, pass the same path through
`--codex-home`. Run the helper on the worker host for remote workers. An idle
status or successful rename delivery alone does not confirm that the name was
saved. If confirmation fails, inspect the preserved terminal and do not send
the assignment or automatically launch a replacement.

This ordering avoids Codex's automatic title-generation model request. A Herdr
terminal label does not set the Codex thread name. Use an explicit name;
bare `/rename` can request a generated suggestion. Existing named sessions
retain their names when resumed. No model, provider, effort or permissions
change is needed for naming.

`herdr-cursor` loads a session-local Cursor plugin that reports `working` on
prompt submission and `done`, `idle` or `error` when the turn ends. It does not
change global Cursor hooks. It cannot detect every permission/trust dialog;
inspect the screen when a wait times out. Workers can explicitly report a
question with `herdr-cursor-status blocked question`. That marker survives the
turn ending and clears when the next prompt is accepted. Other harnesses may
report lifecycle differently; inspect `hc get` and their screen instead of
assuming the Cursor marker exists.

Use `hc wait --children any --timeout 30` while awaiting results, doing useful
independent work between waits. Messages arrive as input. After a report, read
the actual output/artifacts; `hc wait` returns status, not the answer. Read a
worker before retrying a failed send. A reported question blocks normal sends:
check `hc get` shows `kind: question`, read the question and verify that Cursor
is at its ordinary input prompt. Then `hc send --force` may deliver the answer
to that question. Never force-send into a permission, authentication or trust
dialog. Send corrections to the same worker conversation:

```sh
hc send --wait --timeout 30 t001-impl "Fix <specific finding>; rerun <affected check>."
hc read t001-impl --lines 80
```

Children started from a `chief-of-staff` coordinator must never remain in the
`chief-of-staff` tab; place them on separate worker tabs in the same space (up
to 4 splits per tab) using explicit `herdr.space` / `herdr.tab` labels and
`herdr-app ls` verification. Arrange only task-owned splits and tabs to meet the
requested layout. Don't switch Board/Mission or rearrange unrelated work to make
the workflow operate.

## Review, integrate and finish

After implementation, start a fresh read-only reviewer, normally in a different harness
from the implementer, against the frozen candidate in its actual checkout.
Connector-bound tasks keep their reviewer on Codex–OpenAI. For GUI/UI/UX, use
the routing policy's Google design or artifact review and combine reviews where
their scopes permit; do not add redundant review sessions.
Choose its provider, model and effort using the routing policy and project
requirements; Astra/xhigh is not mandatory for every review. For example, for a
difficult Cursor change requiring Astra/xhigh review, launch Codex on the
verified provider without an initial task, then replace `<worker-terminal>`
with the returned terminal address:

```sh
hc run --bg --name t001-review --cwd /absolute/worktree -- \
  codex-openai --model gpt-6-astra -c 'model_reasoning_effort="xhigh"' --sandbox read-only
hc wait <worker-terminal> --timeout 30
herdr-codex-name <worker-terminal> t001-review
hc send <worker-terminal> "<reviewer.md role instructions, review assignment and coordinator address>"
```

Supply the original requirements, baseline/diff,
acceptance criteria and verification evidence, without the implementer's
self-assessment. The managed `codex` launcher already adds `--no-daemon` inside
Herdr; do not add that flag a second time.
Check the name helper's successful confirmation before sending the review.
For other harnesses whose launch includes a task, check `first_message.sent`;
if false, inspect the screen and resolve startup before sending the role
instructions and assignment once.

Require reproducible defects with file/line evidence and practical impact.
Don't use an arbitrary numerical cutoff to dismiss defects. Keep unrelated
pre-existing issues separate, and avoid stylistic churn. Send accepted fixes
back to the original implementer. Review again only for changed behavior,
unresolved findings or missing coverage; reuse valid evidence.

Integrate through one coordinator-owned checkout, preserving unrelated work.
Inspect the actual changes and run the relevant checks after integration.
For UI work, inspect the real app using the project's browser workflow or
Herdr's native screenshot commands. Record what passed and any remaining limits.

After an implementation or review assignment finishes, save its report and
session resume ID when available, then close that harness and its split. If
review finds a fix,
resume the same implementation session in its preserved worktree when possible;
do not leave an idle split open solely for that possibility. After integration
and verification, inspect the worktree for remaining changes and remove the
task-owned worktree and branch when safe. Keep worktrees with unintegrated
changes and preserve the task record and reports. Never stop/restart core as
cleanup. Report the result, verification,
remaining work and any resources intentionally left running. Update the task
record and portfolio, then schedule the next ready job within the shared limit.
The mode does not end merely because this task finished.
