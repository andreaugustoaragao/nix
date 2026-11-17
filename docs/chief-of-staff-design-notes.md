# Chief-of-staff design notes

Maintainer context, not an installed skill reference or startup instruction.

## Operating rationale

The user requires routine subordinate status, text/JSONL inspection and progress
updates only on request. Passive Herdr visibility and actionable completion,
errors, blockers, questions and decisions remain. A bounded assignment includes
checks and evidence; deterministic record work does not need model microtasks.
Necessary raw evidence remains available without repeatedly ingesting transcripts.

A November audit recorded 2,110 Astra/high calls, 789,579,681 input tokens and
784,431,604 cached input tokens. Steve's October approximately $5,000 bill and
counters are attributed figures, not results proven by that November audit. The
November traces do not establish that his revised October workflow failed or show
any savings percentage. Cache reads still have volume and potential cost; actual
billing and accepted-task cost remain distinct from client counters.

Lauren Tan's *All Code Is Slop (Except Mine)*, AI Engineer CODE 2026, November 11:
<https://ai.engineer/code/2026/talks/lauren-tan>; recording:
<https://www.youtube.com/watch?v=ZZ19zhYnDKY>. The organizer transcript is
machine-generated and may contain recognition errors. At 1:03:27–1:04:48 the talk
prioritizes design and static analysis, layers verification, and reserves prose for
judgment; at 1:10:34–1:10:53 it describes encoding corrections or removing invalid
choices; at 1:16:35–1:17:28 it places reliable verification before expanding outer
automation. These are not universal savings or throughput claims.

Apply that lesson only within authorized work: check existing tools; prefer APIs,
ownership and types, then meaningful lint or behavioral safeguards. Verify a real
past failure and valid cases, and wire the safeguard to CI or the operational path.
Do not substitute brittle prose matching for behavior, create a new improvement
queue automatically, or add mandatory ceremonies. Persistent tools need explicit
inputs, useful errors, checks and rerun safety. Broader ideas await prioritization.

The accepted chief-only routing design treats task-fit routes as preferences,
not measured rankings; the Carbon/Astra design-peer gate is user-required rather
than an inference from provider sources. Pstack remains independent and combinable.
The historical material below is retained for maintainers, not loaded at activation.

# Historical routing measurements

Read only when explaining or reassessing the routing policy. These November
2026 WebAI API benchmarks do not measure the user's subscription economics.
The user identifies Codex–OpenAI as the cheapest route within Astra and Sol 6.1;
that preference is not a blanket development assignment.

## Task-fit sources and limits

- Cursor on Grok <https://cursor.com/grok> describes extended engineering across
  files and multi-step tool use; xAI <https://docs.x.ai/developers/grok-4-7>
  distinguishes the paid Fast variant, which this policy does not select.
- Google's Hydrogen introduction <https://blog.google/innovation-and-ai/models-and-research/gemini-models/introducing-gemini-4-hydrogen/>
  and model card <https://deepmind.google/models/model-cards/gemini-4-hydrogen/>
  emphasize disciplined execution, iterative repository coding/debugging and web
  development alongside frontier-model planning.
- OpenAI on Terra <https://openai.com/index/introducing-gpt-6-1-terra/> supports
  efficient coding and computer use while retaining Sol/Astra for the most complex
  coding. Public API prices do not establish this user's routed or subscription cost.
- VS Code's model selection guide <https://code.visualstudio.com/docs/agents/guides/choose-a-model>
  recommends checking real code, tools, follow-ups and usage; its Auto and parallel
  comparison workflow is not adopted here.

These sources support task fit, not a local ranking or the user-required Carbon ↔
Astra peer gate. The repeated LRU/async-memoizer experiment below is narrow, not
representative proof of the development defaults. Effort labels across harnesses
do not establish equivalent budgets. Catalog zeros are placeholders, not free use;
keep unknown cost unknown and API dollars separate from subscription allowance.

## Optional future real-task evidence

1. On the next authorized real regression with reproducible input and visible
   failure, default to Hydrogen; consider Terra only for a concrete routing
   question. Freeze baseline, brief, harness version/tools and checks. Require
   the failure to disappear, adjacent behavior to survive and checks to pass;
   retain review corrections and completion failures.
2. On the next authorized cross-module change with a peer-accepted design,
   default to Grok and retain Sol/Astra as documented escalation when necessary.
   Require observable end-to-end behavior and affected component checks. Escalation
   is recovery evidence, not a matched comparison or a general ranking.

Gather evidence while completing useful work, not a benchmark panel now. If a
later decision requires comparison, propose a small authorized matched replay with
repeat trials, stable acceptance gates and retained failures. Count failures,
retries, required design and candidate review, review fixes and coordinator
recovery in accepted-task cost; keep comparison-only judging overhead separate.

## Cursor Agent capability check and current evidence gap

On 2026-11-14, `cursor-agent status` confirmed authentication, and
`cursor-agent models` listed Carbon and Argon at low, medium and high effort.
The installed `herdr-cursor` wrapper validates an explicit model ID and loads a
session-local lifecycle plugin. This confirms available launch capabilities,
not a completed model task or comparable cost.

T007 used OpenCode2 2.0.18 with WebAI `litellm/gemini-4-carbon`. Its client
reported repeated transport timeouts and exited while correctness corrections
were unfinished. Read-only session records showed completed correction tool
calls before the client exit; the same saved session was resumed. The terminal
also lacked OSC 7501 lifecycle reports. These observations justify reassessing
that route. They do not identify the timeout's root cause or establish another
harness's reliability. The private T007 implementation and recovery artifacts
retain the incident details.

A subsequent Cursor Agent Carbon high review of the isolated T007 snapshot
reproduced defects, including a native `hc ls` versus `hc get` schema mismatch
masked by the implementation's fixtures. The coordinator confirmed that mismatch
against the installed CLI. This demonstrates one completed review capability;
it does not establish a comparative quality, cost or reliability ranking.

The earlier comparison below did not include Cursor Agent. No matched Cursor
Carbon or Argon task series, subscription allowance cost, or live dollar
advantage is established. Cursor's subscription economics must be recorded
separately from the WebAI API costs below. Do not treat an unknown or zero
client cost field as a free completed task.

For a future comparison, use the same isolated task inputs and independent
acceptance checks on Cursor, Pi and OpenCode. Record exact model, effort,
versions and required tools. Alternate the run order, count failures and
retries, and include coordinator recovery and review fixes in accepted-task
cost. Compare coding and review workloads separately. Different effort labels
or missing billing data limit the conclusion. Preserve raw records privately
and publish sanitized aggregates without discarding failed runs.

## Earlier WebAI comparisons

All three harnesses passed all five scored coding sessions for each tested
model. Each session was the same LRU/async-memoizer task plus invalidation,
validated by typechecking and 14 then 19 independent checks. Repetition improves
confidence for this task; it does not add task diversity. Versions were Pi 1.5.2,
OpenCode 2.0.18 and Codex 0.169.0. Native tools/instructions differed.

Mean reported API dollars per accepted two-phase session:

| Model | Pi | OpenCode2 | Codex | Interpretation |
| --- | ---: | ---: | ---: | --- |
| Terra | $0.029044 | $0.050135 | $0.051109 excluding identified titles; $0.062640 total | Pi 42.1% below OpenCode and 43.2% below adjusted Codex; five sessions each. |
| Astra | $0.433260 | $0.591483 | $0.624922 | Pi 26.8% below OpenCode and 30.7% below Codex; five sessions each, no title calls. |
| Carbon, original matched Pi/OpenCode comparison | $0.320094 | $0.257643 | Not a matched three-way comparison | Four complete pairs; fifth pair has missing timeout cost and is excluded on both sides. |

The later one-pair Carbon check at a 32768 ceiling cost $0.24990 for Pi and
$0.26919 for OpenCode, reversing the earlier ordering. Native Codex Carbon's
separate series averaged $0.80073 over four complete records, with a different
protocol, ceiling and collection period. Its custom-profile diagnostics cost
$0.90541 and $0.36754, one session each. Those are configuration evidence, not
fairly interleaved adoption rankings. Terra's resumed fifth Pi session omitted
a small context note; excluding it leaves the cost ranking unchanged.

### Caching: no established harness winner

On the measured Astra WebAI Responses route, all three preserved cache reuse
across visible append-only transitions: 156 of 157 cached the previous input
minus three tokens; the remaining transition cached more. Direct stable-prompt
controls reused about 99.96% at 8k tokens and 99.996% at 80k, including a
30-second idle gap. Front mutation missed; restoring the original prefix hit.

OpenCode's aggregate Astra cached share was 90.58%, Pi's 88.42%, and Codex's
84.43%. Yet Pi cost least: mean new cache-write tokens were 18,703 / 24,537 /
32,761 for Pi / OpenCode / Codex, and output was 4,009 / 4,901 / 4,914. Repeatedly
reading a larger history can raise the hit percentage while increasing cost.
Compare new input, cache reads/writes, output and completed-task cost together.

Google Carbon had higher aggregate cache share in OpenCode (86.9%) than Pi
(83.4%) in the original complete pairs, but lacks the controlled cache experiment
needed to rank Google cache reliability. Carbon diagnostics also retained
unexplained misses. Do not transfer Astra's cache verdict to Google, high effort,
multi-hour sessions or ChatGPT subscriptions. One Astra request took 304 seconds
with a cache hit; delay alone is not evidence of a cache failure. Direct controls
had one exact-output failure out of 65 despite a hit. Server diagnostics were
unavailable through the gateway, and hidden upstream retries/billing are unknown.

Keep stable instructions/tool declarations within a task, append follow-ups and
resume the same suitable implementation session. Avoid gratuitous context
reinjection, model/provider switching and fresh sessions. Still apply necessary
instruction updates and fresh-review isolation. `store:false` did not disable
prompt caching in the measured setup; do not change it to chase cache hits.

### Local resources: choose for the actual workload

Peak process-tree PSS medians in MiB, Pi / OpenCode / Codex: Terra
828 / 886 / 913; Astra 863 / 807 / 986. Ranges overlap; there is no consistent
Pi/OpenCode active-memory winner. Astra CPU-second medians were 6.34 / 7.94 /
6.13; Terra 4.35 / 6.17 / 4.02. Provider waits and a busy host prevent an
intrinsic speed ranking. Single-worker measurements include OpenCode's backend
once; do not multiply that fixed cost by the worker count.

Fresh idle Pi used less memory through four sessions. At eight sessions,
OpenCode sharing one checkout used 1318 MiB versus Pi's 1539; OpenCode in
separate workspaces used 1641. These are short idle observations, not concurrent
coding results. Separate writer worktrees remain mandatory; do not sacrifice
isolation to obtain the shared-checkout number. A long-lived OpenCode backend
also retained memory after clients closed. Reassess actual process-tree PSS
when memory constrains dispatch instead of assuming a universal crossover.

Detailed historical reports include `REPORT.md`,
`CODEX-REPORT.md`, `CONFIG-REPORT.md`, `TERRA-REPORT.md`,
`ASTRA-CACHE-REPORT.md` and `CAPABILITIES.md`. They preserve ranges, deviations,
failures and audit methods. Raw captures remain private; use the reports and
sanitized aggregates when explaining a decision.
