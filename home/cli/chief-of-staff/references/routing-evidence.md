# Historical routing measurements

Read only when explaining or reassessing the routing policy. These November
2026 WebAI API benchmarks do not measure the user's subscription economics.
The user identifies Codex–OpenAI as the cheapest route for Astra and Sol 6.1;
that preference governs current routing.


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

Detailed reports are retained under
`/home/aragao/projects/personal/agent-harness-eval/`: `REPORT.md`,
`CODEX-REPORT.md`, `CONFIG-REPORT.md`, `TERRA-REPORT.md`,
`ASTRA-CACHE-REPORT.md` and `CAPABILITIES.md`. They preserve ranges, deviations,
failures and audit methods. Raw captures remain private; use the reports and
sanitized aggregates when explaining a decision.
