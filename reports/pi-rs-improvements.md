# pi-rs improvements from the native / pi-rs / RTK comparison

Source evidence: [three-way comparison](pi-rs-vs-codex.md), its command data,
and the 45 isolated Codex sessions. Historical observations stay unchanged.

**Complete: all 16 improvements below are implemented and verified in pi-rs
0.3.0.** Rust/Cargo 1.99.0 are active; all 78 direct registry dependencies are
current stable, with six transitive major-version constraints documented below.
The final package builds, 160 Rust tests pass, and Nix checks pass.

The fresh command suite retains 44/45 required facts initially and 45/45 after
recovery, using 67.6% fewer initial output tokens than native. The fresh isolated
model suite returns 45/45 correct answers across all three arms; pi-rs uses 16.8%
less total input than native. These are separate measurements on fixed fixtures.

## Implementation and confirmation checklist

Each item requires implemented behavior and direct verification. A smaller
response is insufficient evidence if the requested information disappeared.

| ID | Required improvement | Evidence needed | Status |
|---|---|---|---|
| I01 | Shorter, selective inline Codex guidance; recommend focused native commands and avoid a separate awareness read | Packaged guidance audit and fresh model sessions | Confirmed: 297 tokens, zero awareness reads; model and package audits below |
| I02 | Plain search/summary CLI output; structured JSON remains explicit and Pi extensions remain compatible | CLI and extension protocol checks; token measurements | Confirmed in regression tests / audit below |
| I03 | Search respects requested context, supports precise literal queries and reliable pagination, and discloses omissions | Overlapping-context, multi-file, Unicode, width and pagination tests | Confirmed in regression tests / audit below |
| I04 | Small listings and already concise output avoid expansion; directory counts become optional work | Output comparisons, filesystem cases and timing | Confirmed in regression tests / audit below |
| I05 | Read budgets depend on output size; preserve moderate files and support targeted line/range/regex recovery | Medium/large/long-line fixtures and recovery tests | Confirmed in regression tests / audit below |
| I06 | Timestamp-aware log grouping retains unique errors, identifiers, warnings and unknown diagnostics | Original log cases plus adversarial log fixtures | Confirmed in regression tests / audit below |
| I07 | Recognized Cargo/pytest summaries retain failures and warnings; unknown formats remain visible | Real passing/failing suites and drift/replay cases | Confirmed in regression tests / audit below |
| I08 | Git history keeps requested depth, authors and formats; compact status/diff retain useful paths and changes | Actual Git repositories, original facts and explicit-format checks | Confirmed in regression tests / audit below |
| I09 | JSON summaries expose structure and exceptional records; precise selection can recover any value | Heterogeneous arrays, middle values, raw payload recovery and selectors | Confirmed in regression tests / audit below |
| I10 | Capture chronological output and provide immediate streaming/passthrough, including follow/watch/interactive commands | Timed first-byte, stdout/stderr ordering, stdin, bytes and exit/signal tests | Confirmed in regression tests / audit below |
| I11 | Deduplicate/compress recovery storage with private atomic writes and bounded retention | Repeated/concurrent storage, corruption, permissions, cleanup and byte-faithful reads | Confirmed in regression tests / audit below |
| I12 | Enforce output budgets, mark every lossy transformation and preserve full output when recovery fails | Byte/Unicode limits, unavailable storage and meaningful omission checks | Confirmed in regression tests / audit below |
| I13 | Preserve native machine-readable formats and conservative rewrite behavior across wrappers | CLI boundary and rewrite regression suite | Confirmed in regression tests / audit below |
| I14 | Update version, package, user documentation and provenance; verify supported platform evaluation | Rust checks, Nix formatting/lint/evaluation/build and packaged CLI checks | Confirmed: final 0.3.0 package and platform checks below |
| I15 | Re-run representative command and isolated model comparisons against the candidate; investigate regressions | Fresh paired data, task correctness, tokens, timing and final requirement audit | Confirmed: 34 command cases, 45 model sessions; regressions and limits below |
| I16 | Update Rust itself and all Rust libraries, resolving compatible API changes and documenting upstream constraints | Official stable toolchain manifest, registry/version audit, lockfile, Nix toolchain and full builds | Confirmed in regression tests / audit below |

Implementation findings and verification evidence are recorded below. Confirmation
means the required behavior passed its checks; comparative performance still
depends on the task and includes the regressions reported here.

## Implemented behavior

pi-rs 0.3 adds plain CLI search/summary, literals, stable pagination, zero default
CLI context, byte-sized reads and targeted recovery. Pi extensions explicitly
request JSON and context. Moderate files and small listings remain intact.
JSON arrays expose sampled shapes and uncommon categorical values; pointers and
array predicates provide exact access.

Wrappers preserve explicit formats. Git history has no implicit depth or format
change. Patch summaries retain changed paths, hunks and values, with exact patch
recovery. Cargo/pytest recognize progress while preserving diagnostics and
unknown output. Log grouping ignores known timestamp/heartbeat counters without
normalizing request IDs. Repeated long-line tokens collapse without hiding labels.

Captured stdout/stderr share one OS pipe. Explicit streaming bypasses argument
preparation; follow/watch/interactive modes stream automatically. Recovery is
content-addressed, optionally gzip, private and atomically published, with age,
file and byte retention. Storage failure returns original output.

## Rust and dependencies

Rust and Cargo **1.99.0** are pinned through `rust-toolchain.toml` and the shared
rust-overlay package. The official stable manifest identifies the 2026-10-01
release. Both the built toolchain and the active shell report 1.99.0.

All **78 direct registry dependencies** match current stable releases.
The [complete dependency audit](data/pi-rs-0.3-dependency-audit.json) records
registry sources, versions, constraints, lock hash and SQL source hashes. The audit
of **232 locked registry entries** checks each version separately, including
coexisting majors. Compatible transitive updates are locked. Six older major
lines remain required by current upstream packages:

| Locked dependency | Newest stable version | Upstream constraint |
|---|---|---|
| getrandom 0.2.17 | 0.4.3 | const-random-macro 0.1.16 requires 0.2 |
| syn 2.0.119 | 3.0.6 | phf_macros 0.14 / tracing-attributes 0.1.31 require 2 |
| r-efi 6.0.0 | 7.1.0 | getrandom 0.4 requires 6 for UEFI |
| redox_syscall 0.5.18 | 0.9.4 | parking_lot_core 0.9 requires 0.5 on Redox |
| wasi 0.11.1+wasi-snapshot-preview1 | 0.14.7+wasi-0.2.4 | getrandom 0.2 requires the older WASI API |
| windows-link 0.2.1 | 0.100.0 | windows-sys / parking_lot_core require 0.2 on Windows |

“Updated” therefore does not mean every transitive entry uses its newest breaking
major. The supported builds also use newer getrandom and syn where supported.
The four platform-specific entries above do not target this flake's Linux/macOS
hosts.

The SQL grammar's cc pin is patched to use **cc 1.6.0**. All 16 retained source
files match the published crate byte for byte. The upstream MIT license omitted
from that crate is included. Existing Clojure/Just manifest patches allow the
shared Tree-sitter 0.27 runtime. All embedded grammars load in the runtime test;
representative parsing checks include the SQL grammar.

## Verification and experiment corrections

- **27 AST + 111 unit + 22 CLI tests pass**. Tests cover all 114 paginated search
  matches, overlapping context, Unicode, a 500-line read, 512-byte output bounds,
  precise gzip recovery, timestamped logs, long-line labels, middle JSON values,
  native formats/help, 25-commit history, central unsafe diff values, immediate
  streaming, stdin, binary bytes, stream chronology, signals and original exits.
- Rustfmt and strict Clippy pass. Vendored C scanners emit upstream compiler
  warnings without failing the build.
- The staged whitespace check passes for maintained files. A scan including
  vendored content reports seven trailing-blank-line warnings in Clojure grammar
  files; that vendored content is preserved.
- Nix formatting, Statix and Deadnix pass. Flake evaluation with
  `--all-systems --no-build` passes, including all configured NixOS hosts. The macOS
  host's system derivation also evaluates explicitly.
- A command pilot exposed a Unix test-fixture race: parallel temporary script
  creation/launch could fail with ETXTBSY. Serializing CLI fixtures fixes it;
  production recovery concurrency retains its threaded test. Pilot/diagnostic
  evidence is preserved separately from the fresh final matrix.
- A model pilot exposed confusing use of `--grep` with `--lines 40`. Guidance now
  distinguishes source-line windows from searching anywhere. All 27 completed
  pilot sessions (9 per arm) are retained separately. Final measurements use
  fresh sessions and are not pooled with the pilot. This is a known fixed suite,
  not held-out workload validation.

A second model snapshot (21 sessions) is preserved as formative evidence.
A passing-pytest output expansion discovered in the command pilot was fixed
before freezing the definitive binary. The final model and command matrices
use that same frozen executable, with neither formative snapshot pooled in.

Formative evidence: [first model pilot](../benchmarks/pi-rs/end-to-end/candidate-0.3/FORMATIVE_PILOT.md),
[second model pilot](../benchmarks/pi-rs/end-to-end/candidate-0.3-final/FORMATIVE_PILOT.md),
and [command pilot archive](data/pi-rs-0.3-formative-command-evidence.tar.gz).

## Definitive command comparison

Fresh 29 primary cases, plus five separately reported synthetic subprocess
replays; 21 randomized timing repetitions per variant. The same Codex cap and
full-response o200k tokenizer accounting apply to every arm.

| Primary metric | Native | pi-rs 0.3 | RTK 0.51 |
|---|---:|---:|---:|
| Initially visible output tokens | 125,633 | 40,710 | 31,415 |
| Required facts initially visible | 41/45 | **44/45** | 40/45 |
| Extra targeted recovery calls | 4 | **1** | 5 |
| Required facts after recovery | 45/45 | 45/45 | 45/45 |

pi-rs uses **67.6% fewer initial output tokens than native** in this suite.
It emits more than RTK because it retains more evidence, including the unsafe
central diff change and complete moderate reads/history. The remaining initial
miss is a function in a large source file; targeted recovery restores it.
These results are not a claim that compression always beats a focused query:
19 focused native queries retain 32/32 facts in 6,030 tokens.

| Selected case | Native tokens | pi-rs tokens | pi-rs result |
|---|---:|---:|---|
| Timestamped log | 16,052 | 148 | Error/request ID retained |
| Long-line log | 7,119 | 186 | Middle line label retained |
| Large JSON response | 12,797 | 200 | Middle exceptional record and total retained |
| Broad search | 785 | 785 | Former expansion removed |
| Passing pytest suite | 116 | 73 | Test total retained |
| Cargo workspace | 3,872 | 1,179 | Success plus diagnostics retained |
| Large diff | 14,321 | 10,550 | Central unsafe setting retained |

The new run creates **44 recovery payloads totaling 153,939 stored bytes**.
The historical run created 308 files / 13,896,806 bytes; the separate runs are
not pooled and the source/test outputs have changed. Direct concurrency tests
independently confirm identical payloads share one compressed file.

Explicit streaming delivers the first byte at a median **11.9 ms**, versus
11.2 ms native. Default summary mode waits until completion (617.7 ms in this
0.6-second fixture). Captured interleaving now preserves `stdout 1 → stderr 2 →
stdout 3`. Warm median case overhead is +3.0 ms for pi-rs and +9.4 ms for RTK;
these are descriptive VM measurements.

Validation checks **121 initial outputs**, token counts at three output caps,
all exit codes and all recovery steps. There are **zero exit mismatches and
zero incomplete recoveries**, including the synthetic replays. Explicit
machine-format output can still be truncated by Codex itself.

Evidence: [details](pi-rs-0.3-command-details.md),
[results](data/pi-rs-0.3-command-results.json),
[aggregates](data/pi-rs-0.3-command-summary.json),
[raw output archive](data/pi-rs-0.3-command-evidence.tar.gz).

### Measurement version and final text correction

Command/model observations pin executable SHA-256
`f52998249e335c775adf45be54067b6ed0c8b929a7e15964374214fe02599745`.
After measurement, a text-only correction replaces the legacy source-summary
`PATH:raw` hint with a valid, shell-quoted `pi-rs read PATH --full` command;
CLI help now accurately describes the available views. Direct verification of
that final hint is recorded separately. The tables retain the actual measured
payloads and do not claim to measure the corrected footer text.

The [final command audit](../benchmarks/pi-rs/end-to-end/candidate-0.3-verified/command-surface-audit.json)
checks all 135 completed model shell events: none invokes source summary or
signature views, so the footer correction is outside the commands exercised by
those sessions. Direct follow-up checks of both summary views retain every
specified fact and verify recovery with filenames containing spaces and
apostrophes. Plain CLI and extension content agree.

## Definitive isolated model comparison

Five fixed tasks × three repetitions × three arms produce **45/45 correct
sessions**, 15 per arm, with requested `gpt-6.1-sol` / medium reasoning. Every
transcript and preflight was audited: the fixture sources remain unchanged,
instruction isolation passes, and executable/toolchain/guidance identities match.

| Metric, 15 sessions per arm | Native | pi-rs 0.3 | RTK 0.51 |
|---|---:|---:|---:|
| Correct tasks | 15/15 | 15/15 | 15/15 |
| Total input tokens | 640,993 | 533,247 | 671,919 |
| Cached input tokens | 421,242 | 328,052 | 471,267 |
| Uncached input tokens | 219,751 | 205,195 | 200,652 |
| Output tokens | 3,303 | 3,003 | 3,348 |
| Sum of session seconds | 179.393 | 164.246 | 190.370 |
| Shell command events | 40 | 41 | 54 |
| Saved-output recovery events | 0 | 3 | 0 |
| Awareness-document reads | 0 | 0 | 15 |

pi-rs uses **16.81% less total input and 6.62% less uncached input than native**.
It reduces total input in 11 of 15 matched task/repetition pairs. RTK uses 4.82%
more total input than native and 26.01% more than pi-rs; its uncached input is
8.69% lower than native and **2.21% lower than pi-rs**. Total input includes
reused cached history and cannot be converted directly into a cost-saving claim.
Session time includes provider latency and is descriptive.

| Task totals | Native input | pi-rs input | RTK input | pi-rs change vs native |
|---|---:|---:|---:|---:|
| Noisy log | 124,292 | 67,245 | 122,522 | −45.90% |
| Configuration diff | 171,569 | 177,298 | 162,137 | +3.34% |
| Source lookup | 136,961 | 105,541 | 151,066 | −22.94% |
| Cargo failure | 107,641 | 79,644 | 100,485 | −26.01% |
| Recent history | 100,530 | 103,519 | 135,709 | +2.97% |

The configuration-diff task accounts for all three pi-rs recovery events.
One initial recovery query returned a broad 31,942-byte selection and needed a
more specific follow-up. All three reads successfully decoded the saved gzip
payload. Recent-history uncached input also increases, from 34,678 to 35,668.
These regressions remain in the totals; the results support selective use of
compression and focused native queries when the target is known.

Inline pi-rs guidance is **297 o200k tokens**, reduced from 634, and requires no
separate awareness read. The final installed guidance exactly matches the source.
RTK's integration performs 15 awareness reads. Its hook audit records 49 intact
matched rewrites and one skip. Two malformed records merge concurrent rewrites,
so intact rewrite counts are lower bounds; the original audit logs are retained.
These measurements compare the complete installed integrations, including their
instructions, hooks, command choices and recovery behavior.

All nine Cargo executions preserve exit 101, the failing test, actual/expected
values 27/25, and 240 passed / 1 failed. The known fixed suite informed the
implementation and guidance changes; it is not held-out workload validation.
Neither model pilot is pooled with these results. The sample does not establish
universal savings or a task-success advantage when all arms already score 100%.

Evidence: [model results](../benchmarks/pi-rs/end-to-end/candidate-0.3-verified/results.md),
[usage aggregates](../benchmarks/pi-rs/end-to-end/candidate-0.3-verified/summary.json),
[fixture integrity](../benchmarks/pi-rs/end-to-end/candidate-0.3-verified/integrity.json),
[prompt isolation](../benchmarks/pi-rs/end-to-end/candidate-0.3-verified/prompt-audit.json),
[hook audit](../benchmarks/pi-rs/end-to-end/candidate-0.3-verified/hook-execution-audit.json),
and [command audit](../benchmarks/pi-rs/end-to-end/candidate-0.3-verified/command-surface-audit.json).

## Final packaged verification

The final Nix package builds as **pi-rs 0.3.0**. Full native `nix flake check`
passes, including its three check builds. `nix flake check --all-systems
--no-build` and explicit macOS system derivation evaluation pass. Rustfmt,
strict Clippy, Nixfmt, Statix and Deadnix all pass; the 160-test suite is green.

The packaged executable reports version 0.3.0 and passes direct checks for
source-matching guidance, byte-identical gzip recovery, correct source line
numbers in targeted recovery, and the final shell-quoted summary hint. Final
source-release SHA-256 is
`80cbc9820393ae810a73660209909f02ad4b367ad41a11ce4884f5e26e83d016`.
The separately built Nix executable has SHA-256
`32eb2547311afd86ab4817c461eb1cac3244072ccba899d9005d67b298d386e7`
and is available at:

```text
/nix/store/jzpl9dbfi4v8m2a31vsxj5vbd1y2dxcp-pi-rs-0.3.0/bin/pi-rs
```

Evidence: [verification results](data/pi-rs-0.3-verification.json),
[verification logs and manifests](data/pi-rs-0.3-verification-evidence.tar.gz),
and [dependency audit](data/pi-rs-0.3-dependency-audit.json).

Rust/Cargo 1.99.0 are already active in the shell. To activate the latest pi-rs
package through this NixOS configuration, rebuild with:

```sh
sudo nixos-rebuild switch --flake /home/aragao/projects/personal/nix#$(hostname)
```
