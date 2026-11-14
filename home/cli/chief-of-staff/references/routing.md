# Routing policy

Read once on activation/resume; reuse until the policy or task requirements
change. These are the user's subscription and workflow preferences. Explicit
task instructions override defaults. Apply connector requirements first, then
model/task fit, then harness tools. Do not balance subscriptions by task count.

## Route and model

| Work | Preferred route | Model |
| --- | --- | --- |
| Email, Google Drive or calendar tasks, including review needing those connectors | `codex-openai`; keep execution on its configured connectors | `gpt-6.1-sol`, or `gpt-6-astra` for difficult synthesis/reasoning |
| General implementation, fixes, refactoring, tests and routine review | `codex-openai` | `gpt-6.1-sol` |
| Complex diagnosis, architecture, high-risk changes and deep review | `codex-openai` | `gpt-6-astra` |
| Google-model work or the UI/UX review below | OpenCode2 / WebAI by default; Pi / WebAI when required tools or observed resource constraints favor it | `litellm/gemini-4-argon` for straightforward work; `litellm/gemini-4-carbon` for complex work |
| Astra/Sol 6.1 work when the OpenAI route is unhealthy or unavailable | `codex-webai`, only under the fallback rule below | Same selected `gpt-6-astra` or `gpt-6.1-sol` |

Codex–OpenAI is the user's cheapest Astra/Sol 6.1 option. Use it for substantial
implementation and review, not just a token share of the backlog. Cursor remains
available for explicit requests or a task-specific capability/allowance reason;
it must not displace a healthy Codex–OpenAI Astra/Sol route merely for balancing.
Terra, Hydrogen and other models are opt-in or need a documented task-specific
reason; the old benchmark defaults do not automatically select them.

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

OpenCode is the WebAI default. Prefer Pi when its direct LSP, Context7, NixOS or
managed-browser integration is needed and unavailable in the selected OpenCode
setup, or measured local resources justify it. Verify current capabilities.
Carbon's observed OpenCode cost advantage is provisional; Argon has no equivalent
comparison. No harness has a proven general cache advantage. Preserve suitable
implementation sessions, stable instructions and append-only follow-ups; name
Codex workers before their first prompt. Fresh review contexts remain necessary.

Give workers only their selected route/model, scoped task, required context and
checks—not this policy, the backlog or benchmark history. Record one routing
reason per assignment and any fallback/UI-review evidence. Capture cost and
rework when available; missing cost is unknown. Inspect detailed measurements
only when explaining or revising a decision: [historical evidence](routing-evidence.md).
