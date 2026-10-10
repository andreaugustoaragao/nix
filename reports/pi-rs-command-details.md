# Command benchmark detail

Generated from the stored command measurements; see the main report for interpretation.

Tokens include fixed execution headers and actual pi-rs JSON/recovery markers, using o200k_base after the 10,000 approximate-token Codex cap.

| Case | Native tokens | pi-rs tokens | Reduction | Facts native / pi / total | Extra pi latency ms (95% interval) |
|---|---:|---:|---:|---:|---:|
| git_status_small | 167 | 77 | 53.9% | 2 / 2 / 2 | +3.89 [+3.64, +4.34] |
| git_status_many | 995 | 423 | 57.5% | 2 / 1 / 2 | +3.90 [+3.59, +4.83] |
| git_log_recent | 2,018 | 289 | 85.7% | 2 / 2 / 2 | +4.13 [+3.82, +4.66] |
| git_log_history | 2,018 | 289 | 85.7% | 2 / 0 / 2 | +3.95 [+3.69, +4.65] |
| git_log_explicit | 289 | 289 | 0.0% | 1 / 1 / 1 | +4.10 [+3.72, +4.37] |
| git_diff_small | 643 | 598 | 7.0% | 1 / 1 / 1 | +3.95 [+2.81, +4.87] |
| git_diff_many | 14,321 | 505 | 96.5% | 1 / 0 / 1 | +3.84 [+3.28, +5.46] |
| git_numstat | 831 | 831 | 0.0% | 2 / 2 / 2 | +2.57 [+2.15, +2.93] |
| git_show_content | 3,625 | 3,625 | 0.0% | 1 / 1 / 1 | +1.70 [+1.43, +2.00] |
| git_global_option | 167 | 167 | 0.0% | 1 / 1 / 1 | +1.74 [+1.26, +2.44] |
| ls_small | 57 | 79 | -38.6% | 2 / 2 / 2 | +0.46 [+0.33, +0.54] |
| ls_many | 527 | 643 | -22.0% | 2 / 2 / 2 | -0.09 [-0.71, +0.75] |
| read_small | 337 | 337 | 0.0% | 1 / 1 / 1 | +0.13 [-0.42, +0.36] |
| read_medium | 3,028 | 1,506 | 50.3% | 1 / 0 / 1 | -0.17 [-0.68, +0.35] |
| read_large | 11,643 | 2,063 | 82.3% | 1 / 0 / 1 | +0.55 [+0.06, +0.72] |
| summary | 11,643 | 1,663 | 85.7% | 3 / 3 / 3 | +7.76 [+7.25, +8.41] |
| signature | 11,643 | 1,663 | 85.7% | 3 / 3 / 3 | +7.16 [+6.88, +7.52] |
| grep_narrow | 52 | 154 | -196.2% | 1 / 1 / 1 | -0.05 [-0.47, +0.04] |
| grep_context | 75 | 154 | -105.3% | 1 / 1 / 1 | -0.28 [-0.42, +0.04] |
| grep_broad | 785 | 3,647 | -364.6% | 1 / 1 / 1 | -0.02 [-0.31, +0.25] |
| log_repeated | 7,011 | 98 | 98.6% | 0 / 1 / 1 | +0.80 [+0.02, +1.12] |
| log_timestamped | 16,052 | 3,268 | 79.6% | 0 / 0 / 1 | +1.22 [+1.01, +1.49] |
| log_small | 41 | 41 | 0.0% | 1 / 1 / 1 | +0.20 [-0.02, +0.47] |
| log_long-lines | 7,119 | 7,119 | 0.0% | 0 / 0 / 1 | +0.95 [+0.39, +1.19] |
| json_values | 12,797 | 919 | 92.8% | 1 / 1 / 2 | -0.79 [-0.93, -0.62] |
| json_structure | 12,797 | 73 | 99.4% | 3 / 3 / 3 | -1.24 [-1.46, -0.95] |
| pytest_pass | 112 | 48 | 57.1% | 1 / 1 / 1 | +8.38 [-7.68, +24.36] |
| pytest_fail | 960 | 559 | 41.8% | 3 / 3 / 3 | +1.95 [-4.02, +5.45] |
| cargo_workspace | 4,088 | 960 | 76.5% | 1 / 1 / 1 | +5.60 [+1.54, +9.09] |
| replay_docker | 7,011 | 98 | 98.6% | 0 / 1 / 1 | +4.21 [+3.52, +5.32] |
| replay_kubectl | 16,052 | 1,269 | 92.1% | 0 / 0 / 1 | +3.04 [+2.51, +4.46] |
| replay_npm | 6,439 | 74 | 98.9% | 1 / 1 / 1 | +2.90 [+2.60, +4.20] |
| replay_gh | 4,224 | 1,747 | 58.6% | 1 / 0 / 1 | +3.56 [+2.55, +4.22] |
| replay_kubectl_json | 12,798 | 12,798 | 0.0% | 0 / 0 / 1 | +1.70 [+0.95, +3.06] |

Negative reductions mean pi-rs expands the response. Negative latency differences are noisy speedups in this warm-cache sample.
The last five cases are synthetic subprocess replays. All 34 native/pi pairs preserved exit status; pytest_fail intentionally returned 1.
Intervals are bootstrap intervals for paired timing differences, not confidence intervals for task success or token savings.

## Recovery at the default cap

| Case | Native extra calls | pi-rs extra calls | pi full read still misses target | pi recovery output tokens |
|---|---:|---:|---|---:|
| git_status_many | 0 | 1 | no | 33 |
| git_log_history | 0 | 1 | not applicable | 38 |
| git_diff_many | 0 | 1 | no | 33 |
| read_medium | 0 | 1 | no | 36 |
| read_large | 0 | 1 | no | 52 |
| log_repeated | 1 | 0 | not applicable | 0 |
| log_timestamped | 1 | 1 | yes | 51 |
| log_long-lines | 1 | 1 | not applicable | 2,733 |
| json_values | 1 | 1 | yes | 37 |
| replay_docker | 1 | 0 | not applicable | 0 |
| replay_kubectl | 1 | 1 | yes | 51 |
| replay_gh | 0 | 1 | no | 54 |
| replay_kubectl_json | 1 | 1 | not applicable | 37 |

Every requested fact was available after the measured targeted recovery. Native recovery assumes a previously saved output file. Git history and unchanged-but-Codex-truncated pi responses required a native rerun/filter because pi-rs produced no tee.

## Efficient native alternatives

These queries are selected with knowledge of the task target; they are not an observed default agent policy.

| Case | Native targeted tokens | pi-rs initial tokens | Native targeted command |
|---|---:|---:|---|
| git_status_small | 77 | 77 | `git status --short` |
| git_status_many | 629 | 423 | `git status --short` |
| git_log_recent | 289 | 289 | `git log --oneline -n 20` |
| git_log_history | 36 | 289 | `git log '--format=%an %s' --grep=revision_005` |
| git_diff_small | 125 | 598 | `git diff -- config.txt` |
| read_small | 68 | 337 | `rg -n -F DEFAULT_HEAD_LINES source/cargo.rs` |
| read_medium | 36 | 1,506 | `rg -n -F critical_timeout=417 medium.txt` |
| read_large | 52 | 2,063 | `rg -n -F 'fn normalize_spans' source/summary.rs` |
| summary | 296 | 1,663 | `rg -n '^(pub )?fn ' source/summary.rs` |
| signature | 296 | 1,663 | `rg -n '^(pub )?fn ' source/summary.rs` |
| log_repeated | 41 | 98 | `rg -n -F ERROR logs/repeated.log` |
| log_timestamped | 51 | 3,268 | `rg -n -F ERROR logs/timestamped.log` |
| log_small | 36 | 41 | `rg -n -F ERROR logs/small.log` |
| log_long-lines | 2,731 | 7,119 | `rg -n -F line=05 logs/long-lines.log` |
| json_values | 68 | 919 | `jq '{total, failed: [.records[] &#124; select(.status == "failed")]}' response.json` |
| json_structure | 60 | 73 | `jq '{total, records: {keys: (.records[0] &#124; keys)}}' response.json` |
| pytest_pass | 48 | 48 | `pytest -q test_pass.py --color=no` |
| pytest_fail | 896 | 559 | `pytest -q test_fail.py --color=no` |
| cargo_workspace | 745 | 960 | `cargo test --workspace --offline --quiet` |
