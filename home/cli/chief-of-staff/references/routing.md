# Routing policy

Read once on chief-of-staff activation/resume; reuse until policy or requirements
change. Explicit task instructions override defaults. Apply connector requirements
first, then task fit and harness tools. These preferences are not measured quality
or price rankings. Never balance subscriptions or equalize task counts. Use
standard speed, never Fast, Auto or an unverified effort variant.

## Route and model

| Work | Preferred route | Model / effort |
| --- | --- | --- |
| Coordination, intake, communication, acceptance and integration | Current chief conversation | Retain the selected session; do not migrate it to match worker routing |
| Small bounded tasks with supplied context and minimal tools | Pi, local by default | Host-configured local model; paid alternatives require explicit selection |
| Routine Google Chat drafting from supplied facts and delivery | `chat-send-task`, fresh minimal Pi/WebAI session, only its delivery tool | `litellm/gpt-6.1-terra`, low effort |
| Architecture/UX design authoring and UI/UX assessment | Cursor `herdr-cursor gemini-4-carbon-high` | Carbon high; observed Cursor failure permits same-model `opencode2 mini --model litellm/gemini-4-carbon`, default effort unqualified |
| Extended cross-module engineering, multi-stage diagnosis and migrations with established design | Cursor `herdr-cursor grok-4.7-high` | Grok 4.7 high normally; verified medium for bounded work, xhigh only with a concrete difficulty reason. Observed Cursor failure permits `opencode2 mini --model litellm/grok-4.7`, default effort unqualified |
| Focused fixes, iterative debugging, tests and narrow refactoring | `opencode2 mini --model litellm/gemini-4-hydrogen` | Hydrogen, default effort unqualified |
| Bounded implementation from a clear specification, established-pattern wiring and coding with computer-use verification | `opencode2 mini --model litellm/gpt-6.1-terra` | Terra, default effort unqualified; verify required tools |
| Independent candidate review | Fresh Carbon or Astra, selected independently of the implementer | Use the exact Carbon route above or Astra route below; preserve connector-bound exceptions and any opposite-model design-peer requirement |
| Email, Google Drive or calendar, including connector-dependent review | `codex-openai`, keep its configured connectors | `gpt-6.1-sol`; `gpt-6-astra` for difficult synthesis/reasoning. Verified medium for bounded Sol work, high for difficult reasoning, xhigh only when warranted and supported |
| Explicit complex-coding escalation or necessary Codex capability | `codex-openai`, with task-specific reason | `gpt-6.1-sol` or `gpt-6-astra`; verify supported effort, high for substantial difficulty, xhigh only when justified |
| Carbon unavailable for design authoring or UI/UX assessment | `codex-openai` | `gpt-6-astra`, high normally; verify at startup and record Carbon's unavailability. An Astra-authored design still requires Carbon peer review |
| Required peer of authored architecture/UX design | Carbon authors → fresh Astra; Astra authors → fresh Carbon | Use the routes above; high normally where qualified, OpenCode default unqualified. Unavailable opposite peer leaves the gate pending |

Sol/Astra also remain available for explicit user selection, required connectors,
necessary harness capabilities or genuinely difficult coding justified by the brief
or observed failures. Record the unresolved difficulty and acceptance gate. Do
not make every implementation, investigation or review an exception. Carbon is
still first for design even when implementation escalates. Development workers
may self-check and run checks, but cannot replace independent acceptance review.

The Chat row is a narrow approved default after matched full-send trials. Pass
only a self-contained brief and the configured route; keep research and source
retrieval in the caller. Exact supplied or reviewed content uses deterministic
`chat-send` with no model. Preserve its operation ID on uncertainty and escalate
browser exceptions without a second submission.

Pi is reserved for small tasks with a self-contained brief, bounded output and
minimal explicitly enabled tools. Keep repository exploration and substantial
implementation in Codex, OpenCode2 or Cursor. Pi loads no automatic project
context, skills, extensions or MCP tools by default. A missing local model or
endpoint failure must not silently select a paid model. Terra Chat remains a
narrow exception to the local default.

## Launch and fallback

Use exact Cursor native IDs; verify available controls at startup. OpenCode 2.0.18
uses interactive `opencode2 mini --model provider/model`; its top-level command
has no `--model`. Configured aliases have no qualified effort variants: do not
invent `#high`, treat `--thinking` as effort, or claim equivalent budgets across
harnesses. Metadata does not prove quota, authentication or tool execution. Reuse
valid discovery and verify the route and required tools at normal startup; no paid
probe is required for this table. Verify browser, image and code-intelligence tools
where needed; LSP availability alone does not select a client.

For Carbon or Grok, an observed Cursor failure permits the same-model OpenCode
route above. Record the failure and reconcile uncertain in-flight work first.
Report unsupported controls instead of silently substituting them. Return new
assignments to healthy Cursor; retain a suitable active fallback until its task
finishes. Cursor allowance and API cost are unknown unless observed; native
Gemini CLI through LiteLLM remains experimental, not an automatic choice.

Use explicit `codex-openai`/`codex-webai` launchers, not bare `codex` with an
assumed provider. Verify route, model, effort and required tools/connectors at
startup. `codex-webai` is authorized for the same Astra/Sol model only after an
observed OpenAI-route failure such as outage, exhausted allowance or persistent
authentication/transport errors. Record and report the reason; reconcile
uncertain in-flight work first. A poor answer, one slow response or subscription
balancing is not a route failure. Keep email/Drive/calendar work on
`codex-openai`; if connectors are unavailable, report the blocker. Return new
assignments to OpenAI when healthy without churning an active fallback session.

## Design, UI and candidate gates

Carbon is first choice for unsettled architecture/UX design and UI/UX assessment.
Every authored architecture/UX design outcome requires a fresh opposite-model
peer: Astra reviews Carbon and Carbon reviews Astra. Give the peer the frozen
design, requirements and evidence. Neither may review its own design, even in a
new session. If the required peer is unavailable, leave the gate pending: never
substitute, self-review or waive it. Fallback authoring may proceed, but dependent
work requiring accepted design waits. Send corrections to the original author
and recheck material revisions with the required peer.

UI assessment inspects rendered states with screenshots or permitted live-app
tools, including hierarchy, flows, interaction, accessibility, visual coherence
and failure states; source alone is insufficient. Assessment of an existing artifact does not itself require a pair.
If it authors a new or revised design outcome, that outcome needs the opposite
peer. Review reports do not recursively require design review.

Candidate acceptance requires a fresh independent Carbon or Astra reviewer,
selected independently of the implementer, normally in a different harness and
with connector-bound exceptions. Supply the actual frozen candidate, requirements
and final verification evidence, not the implementer's self-assessment. Preserve
the opposite-model rule for any Carbon/Astra-authored design outcome. A design
peer accepts the design, not later code. Combine design-peer, UI assessment and
candidate review only when the exact frozen outcome, required scopes, reviewer
independence and evidence all match. Record each gate explicitly; a shared task
ID is insufficient. One qualifying peer can satisfy matching scopes without a
duplicate review.

## Cost and session discipline

The user's cheapest Astra/Sol 6.1 route is Codex–OpenAI; that preference applies
within those models, not as a blanket development assignment. Compare cost per
independently accepted task, including chief, workers, failures, retries, required
design and candidate reviews, review fixes and coordinator recovery. Record
cache-read volume when available; keep API dollars, subscription allowance,
elapsed time and rework separate. Unknown cost stays
unknown; catalog zeros are placeholders, not free usage. Comparison-only judging
overhead is separate. No general cache or harness winner is established.

Keep suitable healthy sessions and stable instructions/tool declarations;
reconcile pending operations before a handoff. Fresh reviews still need independent
context. Name new Codex workers before their first prompt and reuse the same
implementation conversation for corrections when possible. Give workers only
their selected route/model, scoped task, required context and checks. Record one
routing reason and fallback/gate evidence per assignment. Capture usage and rework
when available; missing cost is unknown. For reassessment discipline, see
[evidence guidance](routing-evidence.md).
