# Formative pi-rs 0.3.0 pilot — excluded from final comparison

This stopped run preserves all **27 completed sessions** (9 per arm, all answers correct) of a planned 45-session matrix. It is not the final benchmark and its usage must not be pooled with the final run.

Two pi-rs log sessions combined `--grep` with `--lines 40`, searching only the first 40 source lines. Both returned no match and recovered with native `rg`. The parent requested clearer guidance and a fresh matched matrix. The executable was unchanged.

The in-flight `cargo_failure-2-stock` session finished and was archived. An intentionally pre-created empty fixture stopped the harness at `recent_history-2-rtk` before another model session began. The harness exit status 1 records that administrative stop, not a failed model task. No completed observations were removed, overwritten, or rerun under this tag.

`manifest.json`, transcripts, instruction snapshots, and per-session preflights preserve the original measurements. `pilot-integrity.json` rechecks archived transcripts and fixture integrity. `disposition.json` records the reason and stop boundary. The original manifest deliberately has no `finished_utc`, so the standard final analyzer rejects this incomplete matrix.

`../candidate-0.3-final/` preserves the second formative snapshot. The definitive fresh comparison is `../candidate-0.3-verified/`.
