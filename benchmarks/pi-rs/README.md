# Native Codex, pi-rs, and RTK measurement

The latest report is [pi-rs 0.3 improvements](../../reports/pi-rs-improvements.md).
The original comparison is [pi-rs-vs-codex.md](../../reports/pi-rs-vs-codex.md).
The command benchmark and the isolated Codex task experiment answer different
questions; do not substitute output compression for measured task success.

## Fresh three-way comparison

`compare_rtk.py` regenerates the same 34 fixtures and measures native, pi-rs,
and RTK together. The original two-arm data and harness remain available as
historical evidence. The current RTK binary is the checksum-verified official
v0.51.0 ARM Linux release, commit
`e001f773f80b22b7dc4c7a79521b30e35aaef026`.

```sh
/tmp/pi-rs-bench-venv/bin/python benchmarks/pi-rs/compare_rtk.py \
  --work /tmp/pi-rs-three-reproduction \
  --codex-source-dir /tmp/pi-rs-codex-source \
  --rtk /path/to/rtk --repeats 21
MPLCONFIGDIR=/tmp/pi-rs-mpl /tmp/pi-rs-bench-venv/bin/python \
  benchmarks/pi-rs/summarize_rtk.py /tmp/pi-rs-three-reproduction
```

Use the same prerequisites and plotting library paths described below.
RTK's binary SHA-256 is
`c9a048412139955ce48f85f82065067b524e98b86bf34f012a92a45d719816b5`.
Its release archive SHA-256 is
`8d6d1aad9e69b42481eda7039507d1f7ee93698f87713cecd873d287c1931632`.
The three-way summarizer rechecks output hashes, token counts at all budgets,
facts, recovery payloads, exit codes, and timing sample counts.

Differences from the historical command harness:

- RTK receives native argument equivalents. Source outline/signature intent
  maps to `rtk read --level aggressive`; JSON structure maps to `--keys-only`.
  RTK's ordinary `read` defaults to full content. These commands have different
  output contracts; the comparison checks the same specified task facts.
- RTK gets temporary config, tracking, recall, and legacy tee locations.
  Tracking and default SQLite recovery remain enabled. Telemetry is disabled.
  `RTK_SUPPRESS_HOOK_WARNING=1` removes an installation warning that would not
  occur with its installed integration. Direct-command timing excludes hooks;
  the separate model experiment installs and audits RTK's actual Codex hook.
- Fact checks accept unquoted `total: 500` and `cargo test: N passed` (N > 0)
  as narrowly defined formatting equivalents, consistently across all arms.
- Targeted recovery tries a pi tee or RTK recall hint where one exists. If
  that cannot restore the fact, a native rerun/filter is counted too. Calls,
  output tokens, command tokens, and retrieval results are archived separately.
  No recovery hint is invented for transformations that omit content silently.
- Native's saved-output assumption and all arms' oracle knowledge of targets
  remain optimistic. Recovery is an attainable strategy, not an observed model
  policy. Whole-output rereads are diagnostic alternatives, excluded from the
  chosen targeted-recovery sequence.
- Command-plus-recovery totals exclude instruction documents. The model matrix
  counts the actual provider usage of the installed instruction mechanisms.
- The final dataset includes 21 randomized timing repetitions per variant,
  plus warm-ups. A separate three-repetition pilot is excluded. No fixture was
  removed based on results. The pilot required no command-mapping corrections.
- The original arbitrary-diagnostic streaming replay is retained. RTK emits
  nothing for it; `first_byte_ms` is therefore null. Its initial EOF measurement
  is preserved separately in `eof_ms`. A supplemental Cargo-shaped streaming
  replay determines first-output timing when RTK recognizes the content.
- Every recall hash advertised in initial RTK outputs is read with `--full`
  against a private database copy and verified byte for byte against the stored
  payload. These audit reads are separate from measured task recovery.

The fresh [45-session model matrix](end-to-end/three-way/results.md) uses the
same model and tasks for all three arms; earlier two-arm inference totals are
not pooled into it.

## Command benchmark

Prerequisites: Python 3.13, Rust 1.95, Git, ripgrep, jq, coreutils, and pi-rs 0.2.0.
The Cargo workspace case uses this checkout's `home/cli/pi-rs` with dependencies
and build artifacts already cached. A different source revision changes that case.
Other source inputs are frozen in `source-snapshot.tar.gz`.

```sh
python3 -m venv /tmp/pi-rs-bench-venv
/tmp/pi-rs-bench-venv/bin/pip install -r benchmarks/pi-rs/requirements.txt
python3 benchmarks/pi-rs/fetch-codex-source.py /tmp/pi-rs-codex-source
/tmp/pi-rs-bench-venv/bin/python benchmarks/pi-rs/benchmark.py \
  --work /tmp/pi-rs-command-reproduction \
  --codex-source-dir /tmp/pi-rs-codex-source \
  --repeats 21
MPLCONFIGDIR=/tmp/pi-rs-mpl /tmp/pi-rs-bench-venv/bin/python \
  benchmarks/pi-rs/summarize.py /tmp/pi-rs-command-reproduction
```

On NixOS, the pip plotting wheels also need `libstdc++` and `zlib` available
through `LD_LIBRARY_PATH`. The command benchmark itself does not import NumPy
or Matplotlib. Their older pinned versions avoid an ARM runtime failure seen
with the latest plotting wheels on this VM.

The work directory must not exist. The first tokenization downloads public
vocabularies. No model/API credentials are needed for this benchmark.
The separate [end-to-end experiment](end-to-end/) needs model access.

### Design

- Native programs run through Python argv subprocesses: no shell aliases,
  automatic command rewriting, or global pi-rs instructions affect them.
- pi-rs's executable is resolved to its store path, and its SHA-256 is recorded.
- Both arms use the same fixture, locale, PATH, color settings, Git configuration,
  and completed-process stdout-then-stderr combination. The latter intentionally
  matches pi-rs; the separate streaming probe exposes real chronological differences.
- One warm-up per variant precedes 21 serial, order-randomized pairs. This is a
  warm-cache command-overhead benchmark, not a cold build or inference benchmark.
- The harness compiles the **unmodified** Rust truncation helper from the public
  Codex 0.162.0 commit. Its driver adds Codex's warning/line-count preamble and a
  fixed, equal 25-token execution header. Tokenization and file writes by the
  harness happen outside the timed region; pi-rs's own writes remain timed.
- Output budgets are 1,000, 4,000 and 10,000 approximate tokens (four bytes per
  token in Codex). These are not BPE counts. The resulting visible responses are
  counted independently with `o200k_base` and `cl100k_base`. Neither is claimed to
  be a confirmed GPT-6 billing tokenizer.
- Ordinary Codex model-visible shell responses default to 10,000 approximate
  tokens. In Code Mode, an omitted explicit limit exposes raw output to JavaScript;
  the caller can reduce it before showing it to the model. This benchmark's capped
  response baseline does not model every such programmatic strategy.
- Count the **whole** pi-rs JSON envelope for grep/summary commands. Shell
  integration does not strip their metadata the way the Pi TypeScript extension does.
- Facts are explicit strings tied to a task: a modified option, an error request
  identifier, a historical author, a function name, or a particular assertion.
  Retention is a diagnostic availability metric, not an LLM accuracy score.
- The `focused` variant uses task-specific native flags/queries and is reported
  separately. It is an efficient native alternative, not a randomized agent arm.
- Docker, kubectl, gh and npm cases are **synthetic output replays**, using named
  subprocess stubs. No live container service, cluster, account, or package install
  is benchmarked. Real Cargo/pytest executions are separate cases.
- Recovery uses one targeted `rg` query for all missing facts. Native recovery
  assumes the original output was already saved by a planned redirection. This is
  optimistic for native commands. Both sides know the exact task target; measured
  recovery tokens are attainable lower bounds, not predicted agent behavior.
- A full `pi-rs read --no-truncate` of each needed tee is also measured. Codex may
  truncate that response again; targeted reading can therefore be necessary.
- The benchmark preserves all cases, including expansion, missing information,
  neutral pass-through, failures and small outputs. Aggregates are fixture totals,
  not estimates of the user's unknown workload distribution.

`results.json` includes each command, exit status, token counts, fact retention,
all timings, paired median-difference bootstrap intervals (2,000 resamples, seed
937), tee storage, recovery and streaming measurements. `evidence/` contains raw
outputs. `manifest.json` is written before measured commands run. Bootstrap
intervals reflect timing noise within this one machine/run, not workload sampling.

Two pilot-driven fixture corrections precede the final run: the GH replay uses
issue-shaped rows, and the pytest failure case checks the middle assertion as
well as its test name. During validation, the two focused JSON queries were
corrected to include every requested key; both cases were rerun in full.
No case was removed based on its result.

### Source snapshot and licenses

The archive contains copies of this repository's pi-rs source and global Codex
guidance. `summary.rs` and `ops.rs` derive from oh-my-pi; see
[pi-rs NOTICE](../../home/cli/pi-rs/NOTICE) and
[pi-ast LICENSE](../../home/cli/pi-rs/crates/pi-ast/LICENSE).
Codex source is fetched from OpenAI's Apache-2.0 repository with immutable commit
and SHA-256 checks, rather than silently following its main branch.

## Interpretation

Instruction overhead is counted once per fresh session in context totals. Actual
API input usage may charge the same history on multiple turns and apply caching.
Only the isolated model experiment can measure those effects. No command-level
percentage is a claim about total API cost, coding quality, or user wait time.

## pi-rs 0.3 verification

The 0.3 follow-up uses fresh regenerated fixtures and the same 21 randomized
repetitions. `compare_rtk.py --pi-stream --pi-guidance PATH` additionally records
explicit native streaming and the candidate's actual guidance size. Gzip recovery
is decoded with pi-rs itself, and the full payload is checked against the
decompressed stored bytes. Legacy plain tee recovery remains supported.

The current CLI emits plain search/summary text, so the shell comparison measures
that actual payload rather than the former implicit JSON envelope. The final
source/test suite is frozen before its Cargo case runs. Test fixture launches
are serialized to avoid Unix ETXTBSY races from concurrent temporary script
creation. An unstable exit stops the matrix and archives its output.

The [improvement report](../../reports/pi-rs-improvements.md) separates formative
runs, [final command results](../../reports/pi-rs-0.3-command-details.md), and the
[45-session model experiment](end-to-end/candidate-0.3-verified/results.md).
All 45 sessions are correct. The final command and model runs use Rust 1.99.0
and the same measured pi-rs 0.3 executable; the report discloses the subsequent
summary/help text correction and its separate verification. Historical
reports/data are preserved.
The final fixed suite has informed implementation and guidance changes; it is
not a held-out production workload sample.
