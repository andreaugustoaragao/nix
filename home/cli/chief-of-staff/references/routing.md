# Routing policy

Read once on activation/resume; reuse until the policy or task requirements
change. These are the user's subscription and workflow preferences. Explicit
task instructions override defaults. Apply connector requirements first, then
model/task fit, then harness tools. Do not balance subscriptions by task count.

## Route and model

| Work | Preferred route | Model |
| --- | --- | --- |
| Routine Google Chat drafting from supplied facts and delivery | `chat-send-task`, fresh minimal Pi/WebAI session, only its delivery tool | `litellm/gpt-6.1-terra`, low effort |
| Email, Google Drive or calendar tasks, including review needing those connectors | `codex-openai`; keep execution on its configured connectors | `gpt-6.1-sol`, or `gpt-6-astra` for difficult synthesis/reasoning |
| General implementation, fixes, refactoring, tests and routine review | `codex-openai` | `gpt-6.1-sol` |
| Complex diagnosis, architecture, high-risk changes and deep review | `codex-openai` | `gpt-6-astra` |
| Google-model work or the UI/UX review below | Cursor Agent through `herdr-cursor`, OpenCode2 / WebAI, or Pi / WebAI; choose by required tools, observed reliability and task evidence | Argon for straightforward work; Carbon for complex work. Verify the exact harness-specific model and effort below. |
| Astra/Sol 6.1 work when the OpenAI route is unhealthy or unavailable | `codex-webai`, only under the fallback rule below | Same selected `gpt-6-astra` or `gpt-6.1-sol` |

Codex–OpenAI is the user's cheapest Astra/Sol 6.1 option. Use it for substantial
implementation and review, not just a token share of the backlog. Cursor remains
available for explicit requests or a task-specific capability/allowance reason;
it must not displace a healthy Codex–OpenAI Astra/Sol route merely for balancing.
The Chat row is the user's approved task-specific default after matched full-send
trials. Pass only a self-contained brief and the configured route; keep research
and source retrieval in the caller. Exact supplied or reviewed content uses the
deterministic `chat-send` command with no model. Preserve its operation ID on
uncertainty and escalate browser exceptions without a second submission.
Other Terra/Hydrogen tasks remain opt-in or need a documented task-specific
reason; the Chat default does not change unrelated model routes.

Use the explicit `codex-openai`/`codex-webai` launchers, not bare `codex` with an
assumed provider. Verify the installed route, exact model, effort and needed
connectors/tools at startup. A subscription route is separate from a harness;
WebAI's API dollars are not subscription credits. Select effort for difficulty,
subject to project/user requirements; avoid maximum effort for mechanical work.

Fallback is authorized for observed OpenAI-route failure, such as outage,
exhausted allowance or persistent authentication/transport errors. Record and
report the reason before using `codex-webai`; retain the task/model and reconcile
any uncertain in-flight work first. A poor answer, one slow response or a desire
to use another subscription is not a route failure. Keep email/Drive/calendar
work on `codex-openai`; if its connectors are unavailable, report the blocker
rather than moving the task to WebAI. Return new assignments to OpenAI when
healthy without churning an active fallback session.

## Google review for GUI/UI/UX

Include a Carbon or Argon review in GUI/UI/UX development: choose design review
before implementation when direction/flows are unsettled, or review the actual
rendered artifact when a concrete result is available. Argon suits small,
established patterns; Carbon suits complex interactions, novel layouts or major
redesigns. This is the user's quality preference, not a benchmark-proven ranking.

Review hierarchy, flows, interaction states, accessibility and visual coherence.
For artifact review supply screenshots or the permitted live-app tools; a source
diff alone does not establish UX quality. Use one appropriate review stage and
combine it with the existing independent review when scope permits; add another
only for material changes or missing evidence. The implementer may stay on
Codex–OpenAI. Independent review uses fresh context, normally a different harness;
connector-bound tasks remain on Codex–OpenAI even when reviewed.

## Keep routing inexpensive

Cursor Agent is approved for Carbon and Argon. For Herdr workers, use
`herdr-cursor` with an exact ID from `cursor-agent models`. The catalog currently
lists `gemini-4-carbon-{low,medium,high}` and `gemini-4-argon-{low,medium,high}`.
Pi and OpenCode use the `litellm/` IDs above; verify their effort controls
separately. Matching labels do not prove equal reasoning budgets. Preserve
permissions and never silently select Auto.

There is no general Carbon or Argon harness winner. The narrow Carbon
Pi/OpenCode comparison is provisional, a later pair reversed the ordering, and
Cursor has no matched comparison. T007's OpenCode timeouts warrant reassessment
but do not prove another route is better. Choose by required tools and observed
behavior. Prefer Pi when a task needs its direct integrations and alternatives
lack them. Verify current capabilities.

Compare cost per independently accepted task, including failures, retries,
review fixes and coordinator recovery. Match task inputs and acceptance checks,
record versions and effort, alternate order, and retain failures. Keep API
dollars, subscription allowance and elapsed time separate. Unknown cost stays
unknown; a client zero is not proof of free use. No general cache winner is
established. Keep suitable healthy sessions and stable instructions. Reconcile
old sessions and pending operations before a route handoff. Fresh reviews still
need independent context; name new Codex workers before their first prompt.

Give workers only their selected route/model, scoped task, required context and
checks—not this policy, the backlog or benchmark history. Record one routing
reason per assignment and any fallback/UI-review evidence. Capture cost and
rework when available; missing cost is unknown. Inspect detailed measurements
only when explaining or revising a decision: [historical evidence](routing-evidence.md).
