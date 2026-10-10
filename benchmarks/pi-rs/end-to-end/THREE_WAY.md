# Adding RTK: fresh native / pi-rs / RTK sessions

The new comparison is [`three-way/results.md`](three-way/results.md), with full
per-run evidence in [`three-way/manifest.json`](three-way/manifest.json),
`three-way/transcripts/`, and `three-way/rtk-observation/`. The prior two-arm
experiment remains unchanged and is not pooled into this matrix.

The completed matrix produced **15/15 correct answers in every arm**. Total
input was 583,172 native, 484,777 pi-rs, and 666,064 RTK; uncached input was
218,674, 201,200, and 204,518 respectively. Thus pi-rs used 16.9% less total
input than native, while RTK used 14.2% more total input but 6.5% less uncached
input. RTK had 55 command events versus 38 native and 39 pi-rs, including an
awareness-document read in all 15 RTK sessions. These results reflect the whole
integration, including those reads and other model decisions; they do not assign
the entire difference to the awareness document or compression alone.

## Experiment

The same five generated repositories, task questions, answer schemas, and source
integrity checks from the earlier experiment are reused. All three arms run
contemporaneously with **Codex CLI 0.162.0, requested gpt-6.1-sol, medium reasoning**,
regardless of the user's current model preference. Provider settings are captured
once before the run. Backend routing is not independently verified.

There are three repetitions of each task in each arm: **45 sessions**. Within each
task, the order rotates through native, pi, and RTK so each occupies the first,
second, and third position exactly once. The task text now explicitly allows
reading installed agent instruction documents, equally in all arms, because the
official RTK integration references a separate instruction file outside the
fixture. Recovery reads remain allowed. Models choose their own commands and
batching; no verbose baseline command is forced.

| Arm | Integration supplied |
|---|---|
| Native | Built-in Codex instructions/tools; no user compression guidance or hooks |
| pi-rs | The deployed pi-rs 0.2.0 global inline `AGENTS.md`; no rewrite hook |
| RTK | Official RTK 0.51.0 `rtk init -g --codex`: global `AGENTS.md` reference, `RTK.md` at default awareness, and actual `rtk hook codex` PreToolUse hook |

This compares usable integration bundles. RTK's automatic rewriting, its default
instruction text, and the extra read of its referenced document are part of that
bundle. The experiment does not isolate binary compression as the sole cause of
whole-task differences.

## RTK provenance and defaults

The unmodified release binary is pinned to version 0.51.0 and SHA-256
`c9a048412139955ce48f85f82065067b524e98b86bf34f012a92a45d719816b5`.
Source commit: `e001f773f80b22b7dc4c7a79521b30e35aaef026`.
The parent experiment verified the downloaded release archive against GitHub's
published digest. The binary lives under `/tmp/pi-rs-rtk-0.51.0/rtk`; it is not
installed into the user's actual configuration.

The installed files and printed defaults are archived in `rtk-installed/`:

- `AGENTS.md` contains `@/home/aragao/.codex/RTK.md`.
- `RTK.md` contains the shipped ownership header and default awareness text.
- `hooks.json` uses the official `Bash` matcher and `rtk hook codex` command.
- Awareness remains `default`; recovery remains the default **SQLite** mode,
  tracking stays enabled, and all compression/limit defaults are retained.
- `RTK_TELEMETRY_DISABLED=1` is set in every arm. Other inherited `RTK_*`
  overrides are removed. `RTK_HOOK_AUDIT=1` enables diagnostic rewrite logging;
  it does not change rewrite or compression decisions.

No manually authored RTK prefix adapter is used. In the feasibility pilot, the
model issued native commands; the real hook rewrote four of them. Four changed
commands appeared in Codex execution events, and all four appeared in RTK's
history database. One was the initial `cat` of RTK's awareness document, rewritten
to `rtk read`. Native and pi arms had no RTK hook or history activity.

## Isolation and hook trust

The direct npm Codex binary bypasses the user's launcher. Each session uses a
fresh fixture and a `bwrap` mount namespace with a read-only root and writable
`/tmp`. Fresh directories are mounted at the existing `~/.codex`, `~/.local/share`,
and `~/.config` paths. This creates the default pi/RTK storage paths without
creating host directories. **HOME and CODEX_HOME are not changed**, and the real
user directories are not modified. These parent-directory mounts are identical
in all three arms; all use the same additional inner-sandbox writable data root.

The same custom skills, plugin/app tools, memories, web search, shell snapshots,
login shells, user CLI configuration, project instruction discovery, and
execpolicy rules are disabled as in the original controlled baseline. Native
operating-system tools, system-level requirements, and provider infrastructure
are shared. This is not a fresh operating-system image.

Only RTK's arm enables `features.hooks=true`. Its known, reviewed hook uses
`--dangerously-bypass-hook-trust` to avoid an interactive trust prompt in the
fresh isolated state. This flag **does not disable the command sandbox or native
approval checks**. No other hooks are installed there; the native and pi arms
keep hooks disabled. The ordinary read-only task restrictions apply to every arm.

The hook is not assumed to rewrite every command. Unsupported shell constructs,
including certain substitutions or redirections, can correctly pass through.
`rtk-observation/` preserves the native hook audit's rewrite/skip decisions and
sanitized SQLite command/recovery metadata. CLI events show the commands that
actually execute. A compound shell call can yield one hook decision and several
tracked RTK subprocesses; these counts are deliberately reported separately.

The full matrix exposed a diagnostic limitation: two simultaneous RTK hooks can
interleave writes to `hook-audit.log`, merging their timestamp, action, and command
fields. The raw corrupted lines are preserved. Parsed rewrite counts therefore
describe intact records and can undercount the rewrites. Every intact replacement
is matched to an actual completed command. Completed command events and SQLite
history separately confirm RTK execution even when its text audit is corrupted.
This auxiliary logging defect did not prevent those commands from running.

## Observed command and recovery behavior

- All three RTK Cargo runs retained enough failing-test detail for the exact
  answer and created a SQLite recall entry. The model did not need `rtk recall`
  or `rtk proxy` in any of the 15 RTK sessions.
- All three pi-rs diff sessions solved the hidden configuration change using
  generated recovery output, with four recovery-command events in total.
  RTK solved those tasks with targeted source reads and diffs that ignored the
  irrelevant comment changes; one session also used a native Git inspection
  inside a Python heredoc, which the hook correctly left unchanged.
- RTK executed 52 shell calls containing its binary, representing 62 tracked
  RTK subprocesses because some calls batched several commands. There were 48
  intact rewrite audit records and three intact skip records. Two corrupted
  records each merge two concurrent hook log entries; their four RTK shell
  calls are still visible in completed execution events and SQLite history.
- RTK's 30 CLI `error` items are duplicate hook-trust-bypass notices; there were
  no other such error items. All 45 sessions completed with exact answers,
  unchanged tracked source, and no unexpected new files.

## Measurement and validation

The same measurement cautions from [README.md](README.md) apply:

- Provider-reported cumulative input includes repeated and cached context.
  Uncached input is input minus cached input. Cache-write input is archived
  separately, and no dollar pricing is assumed.
- Output tokens, wall time, actual command events, command-output bytes,
  instruction-file reads, recovery calls, hook rewrites/skips, and RTK history
  activity are recorded. RTK's own estimated token-savings fields are supporting
  diagnostics, not substitutes for Codex usage measurements.
- Timing covers the Codex process. Fixture generation and installing the
  integration into fresh state occur before the timer, as setup rather than
  task execution. Reading RTK's awareness document during the task is included.
- Codex emits its hook-trust-bypass notice twice per RTK session as an `error`
  item, even when execution succeeds. These notices are counted separately from
  other error items; they are not labeled failed RTK commands.
- Command-output bytes are sanitized event payloads; they are not exact
  model-visible token counts. Native PTC/direct invocation arguments and output
  budgets are not available from these event transcripts.
- A successful task requires the exact answer, any required actual test run,
  unchanged tracked source, and no unexpected new files. Rust's generated
  `Cargo.lock` and ignored build directory are allowed. Failures are retained.
- `analyze_three.py` independently reconstructs each recorded result from its
  transcript and RTK metadata, verifies fixture integrity, checks contamination,
  and computes all three paired comparisons. Paired bootstrap intervals describe
  variation on these five fixed tasks, not all development work.
- `audit_three.py` archives initial instruction-loading audits. Codex receives
  RTK's shipped file reference; actual awareness reads are visible in session
  events. The debug audit is not claimed to be the full executed API request.

`three-pilot/` contains one separate source-lookup triple used to verify the
integration. It is excluded from the full matrix. No model outcome is removed
because it favors a particular arm.

## Reproduce

Same prerequisites as [README.md](README.md), plus the pinned RTK release binary
and matching source checkout at the paths in `run_three.py`:

```sh
python3 benchmarks/pi-rs/end-to-end/run_three.py --tag three-rerun --repeats 3
python3 benchmarks/pi-rs/end-to-end/audit_three.py three-rerun
python3 benchmarks/pi-rs/end-to-end/analyze_three.py three-rerun
/tmp/pi-rs-bench-venv/bin/python benchmarks/pi-rs/end-to-end/measure_instructions.py three-rerun
```

The tag must be new. Scripts stage their generated report artifacts, do not
commit, and leave temporary fixture/data directories for integrity auditing.
They use the existing provider authentication command without archiving its
credentials or endpoint. Fresh local state does not clear provider-side caches.
The optional last command uses the parent command benchmark's `tiktoken`
environment to measure instruction payloads under `o200k_base` and `cl100k_base`.
Those standalone counts exclude framing and repeated-context costs and are not
represented as the private model's billing tokenizer.

## RTK sources

- [Official Codex hook integration](https://github.com/rtk-ai/rtk/blob/e001f773f80b22b7dc4c7a79521b30e35aaef026/hooks/codex/README.md)
- [Default awareness](https://github.com/rtk-ai/rtk/blob/e001f773f80b22b7dc4c7a79521b30e35aaef026/hooks/rtk-awareness.md)
- [Native Codex hook processor and audit logging](https://github.com/rtk-ai/rtk/blob/e001f773f80b22b7dc4c7a79521b30e35aaef026/src/hooks/hook_cmd.rs)
- [Default recovery settings](https://github.com/rtk-ai/rtk/blob/e001f773f80b22b7dc4c7a79521b30e35aaef026/src/core/retriever.rs)
