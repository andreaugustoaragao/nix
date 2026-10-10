# Isolated Codex sessions: pi-rs versus native commands

For the newer comparison including RTK, see [THREE_WAY.md](THREE_WAY.md) and
[the fresh three-arm results](three-way/results.md). This file documents the
preserved earlier two-arm experiment.

The accepted experiment is [`verified/results.md`](verified/results.md). Its
machine-readable inputs and outcomes are in [`verified/manifest.json`](verified/manifest.json),
and the full sanitized CLI event transcripts are in `verified/transcripts/`.
The main report in `reports/pi-rs-vs-codex.md` combines these results with the separate
command-level experiment.

## Design

Five deterministic synthetic repositories model common read-only investigation
tasks. Each task receives three independent runs in each arm: 30 sessions, 15
paired comparisons. The first arm alternates by task and repetition. The model
chooses its own commands, output limits, searches, and batching. No prompt forces
the native arm to print an entire file or use verbose commands.

| Task | Required evidence | Checker |
|---|---|---|
| `noisy_log` | First failed request in 10,501 log lines, with long repeated healthy/retry runs | Exact timestamp, upstream, error code |
| `config_diff` | One changed authentication flag among build-stamp comments in 120 changed config files | Exact file, setting, previous and new value |
| `source_lookup` | Checkout policy among 19 Python source files | Exact integer timeout and retries; no app execution |
| `cargo_failure` | Run 241 local Rust tests, one failing assertion | Exact test, actual/expected values, pass/fail counts; a Cargo test command must occur |
| `recent_history` | Most recent TTL change among nine Git commits | Exact seven-character commit, subject, previous/current TTL |

`run.py` contains all fixture generation, prompts, schemas, and answer keys.
`analyze.py` also compares all tracked fixture contents against their original
templates, checks for unexpected new files, and verifies required test execution.
Cargo-generated `Cargo.lock` and ignored `target/` build outputs are permitted.

## What “stock” means here

This is a controlled native-command baseline using installed Codex CLI 0.162.0,
requested model `gpt-6.1-sol`, medium reasoning, and the user's existing model
provider/authentication command. The selected model and provider are held fixed;
this is not a claim about the default model or behavior of every Codex product.
The gateway's backend routing is not independently verified.

Both arms keep the CLI's built-in model instructions and native tools. User
configuration, custom instructions, project instruction discovery, execpolicy
rules, hooks, plugin/app tools, skills catalogs, memory, web search, shell
snapshots, and agent delegation are removed or disabled in both arms. Login
shells are disabled. A shared prompt permits local investigation and generated
recovery-file reads, prohibits source edits, network use, and spawning agents,
and asks for a final schema-constrained JSON object.

The treatment alone receives the complete deployed pi-rs 0.2.0 guidance as its
global `AGENTS.md`. Its bytes and SHA-256 are archived, including the existing
unverified savings claims. Its instruction overhead is included in measured
input usage. Native commands remain available in this arm; actual adherence is
recorded. The installed pi-rs binary is resolved and pinned in `PATH` for both
arms. Merely having the binary available does not rewrite native commands.

### Isolation details

The direct npm CLI path bypasses the user's launcher. `bwrap` exposes a read-only
root, writable `/tmp`, and fresh per-session directories mounted at the existing
`~/.codex` and `~/.local/share/pi-rs` paths. `HOME` and `CODEX_HOME` are not changed,
and no actual user configuration is modified. Only the existing provider and its
auth command are passed as private configuration arguments; URLs and credentials
are not archived. Each session has a fresh fixture copy and empty Codex state.
Both arms receive the same additional writable recovery directory, backed by a
temporary mount. CLI `--ephemeral` prevents session-history persistence.

Mount isolation matters: in the installed version, `--ignore-user-config` and
`project_doc_max_bytes=0` alone do **not** disable global `~/.codex/AGENTS.md`.
The source always installs `CodexHomeUserInstructionsProvider`, whose contents
are loaded independently of the project-document byte limit. Archived
`codex debug prompt-input` audits confirm no global pi guidance or skill catalog
in stock, and exactly one copy of pi guidance in treatment. These audits verify
instruction loading; the debug command does not reproduce the full executed API
request or execution-tool arguments. Both arms still inherit the same operating
system, executables, system-level requirements, native Git configuration, and
provider. This is isolation of the pi-related treatment, not a fresh OS image.

## Measurements and limits

- `turn.completed.usage` is the CLI's provider-reported cumulative usage over
  model requests: input, cached input, cache-write input, output, and reasoning.
  Input includes repeated/cached context. Uncached input is input minus cached
  input. Provider billing may treat cache writes differently; no dollar estimate
  is invented. Reasoning tokens are reported separately, never added to output.
- Wall time covers the complete CLI process, including startup, provider delay,
  and commands. Fresh Rust builds occur independently for both arms. Service
  latency and natural model variation remain; paired runs do not remove them.
- Command count is the number of completed `command_execution` events. Logged
  command-output bytes are measured **after sanitizing paths and URLs**. These
  events may differ from what the model ultimately saw. They are not labeled
  model-visible token counts. The events omit the original PTC/direct tool call
  arguments and per-call output budgets, so this experiment cannot distinguish
  those invocation paths or reconstruct their exact truncation decisions.
- Whole-task savings include changed command selection, batching, native concise
  searches, pi compression, instructions, and recovery. A decrease in total
  input is not proof that compression alone caused the entire decrease.
- Prompt caching is not disabled. Fresh local state does not clear provider-side
  caches; cached and uncached usage are reported separately. Order alternates,
  but this is a small fixed suite, not a random sample of development work.
- The bootstrap interval resamples paired repetitions within each fixed task;
  it describes variability on these tasks and does not establish production-wide
  superiority. Equal correctness on a small set cannot prove improved accuracy.
- The provider model-discovery endpoint emitted decode warnings; Codex still
  completed sessions using the requested model and bundled model metadata.
  Warnings are preserved in sanitized stderr files. No successful run is removed
  because it favors either arm.

## Protocol development, kept separate

`pilot/` has four completed feasibility sessions (one source and one Cargo pair).
They verified real usage events and answer parsing. Deprecated feature aliases
were then removed and identical writable recovery-directory permissions were
added to both arms. The initial Cargo pilot could not persist its recovery log
inside the inner sandbox, so pi-rs correctly fell back to the full raw output.
The accepted experiment permits isolated recovery storage; its Cargo outputs
elide 203 lines while retaining the failing assertion and test counts.

`main/` is an **excluded preliminary run**, not the accepted result. Its original
shared prompt forbade reading outside fixture directories without an explicit
exception for generated recovery files. That could handicap pi-rs. Seven
completed sessions are preserved; `cargo_failure-1-stock` was interrupted while
correcting the protocol and has no recorded completion or usage. The correction
was independent of scored outcomes. `verified/` reruns the entire planned matrix
with the exception explicitly allowed equally in both arms. These preliminary
observations are not pooled into the final statistics.

## Reproduce

Requires this machine's direct Codex CLI, configured provider auth command,
Linux `bwrap`, Python 3.11+, Git, Rust/Cargo, and pi-rs. The configured model and
reasoning must match the recorded manifest for a like-for-like rerun. Models and
timing are nondeterministic. Live Codex sessions incur provider usage.

```sh
python3 benchmarks/pi-rs/end-to-end/run.py --tag rerun --repeats 3
python3 benchmarks/pi-rs/end-to-end/audit_prompt.py rerun
python3 benchmarks/pi-rs/end-to-end/analyze.py rerun
```

The tag must be new. These scripts stage their new repository artifacts, as
required by this repository's instructions, and do not commit. Generated
temporary fixtures are retained for the integrity audit. Analysis can be rerun
later from the archived integrity evidence after those temporary directories
are removed. `verified/summary.json` includes all paired values and descriptive
statistics; `verified/integrity.json` records the source audit.

## Source references

Implementation inspected at the public tag corresponding to installed CLI
0.162.0, commit `c1382380de69521303b416720a52f42d51af6248`:

- [Global instruction provider](https://github.com/openai/codex/blob/c1382380de69521303b416720a52f42d51af6248/codex-rs/app-server/src/message_processor.rs)
- [Instruction loading independent of repository limit](https://github.com/openai/codex/blob/c1382380de69521303b416720a52f42d51af6248/codex-rs/core/src/agents_md_manager.rs)
- [CLI cumulative usage-event mapping](https://github.com/openai/codex/blob/c1382380de69521303b416720a52f42d51af6248/codex-rs/exec/src/event_processor_with_jsonl_output.rs)
- [CLI configuration schema](https://github.com/openai/codex/blob/c1382380de69521303b416720a52f42d51af6248/codex-rs/core/config.schema.json)
