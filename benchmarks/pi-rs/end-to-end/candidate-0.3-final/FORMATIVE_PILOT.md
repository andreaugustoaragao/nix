# Second formative pi-rs 0.3.0 pilot — excluded from final comparison

Despite the historical directory name, this is a **formative snapshot**, not the final comparison. It preserves all **21 completed sessions** (7 per arm, all answers correct) from the planned 45-session matrix. Its usage must not be pooled with a later final run.

The separate command benchmark exposed a pytest summary regression on a small passing suite: native output used 115 reference tokens, while candidate output used 137. The parent requested a corrected executable before continuing. These model fixtures use Cargo rather than pytest; the stop was triggered by the separate command benchmark, not a failed model task.

The in-flight `config_diff-2-pi` session finished and was archived. An intentionally pre-created empty fixture stopped the harness at `source_lookup-2-stock` before another model session began. Harness exit status 1 records the administrative stop. No completed observations were removed, overwritten, or rerun under this tag.

The original manifest, transcripts, instruction snapshots, and per-session preflights preserve the measurements. `pilot-integrity.json` rechecks archived transcripts and fixture integrity; `disposition.json` records the reason and boundary. The original manifest has no `finished_utc`, so the final analyzer rejects this incomplete matrix.

Guidance was unchanged after this snapshot. The definitive fresh matrix pins the corrected executable under `../candidate-0.3-verified/` and preserves its own independent measurements.
