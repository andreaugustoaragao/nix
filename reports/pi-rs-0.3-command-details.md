# Native / pi-rs / RTK: command details

Fresh measurements on identical regenerated fixtures. N = native, P = pi-rs 0.3.0, R = rtk 0.51.0.

Tokens use o200k_base after the same Codex 10,000 approximate-token cap, with fixed execution headers.

| Case | N tokens | P tokens | R tokens | Facts N / P / R / total | Exit N / P / R |
|---|---:|---:|---:|---|---|
| git_status_small | 167 | 77 | 80 | 2 / 2 / 2 / 2 | 0 / 0 / 0 |
| git_status_many | 995 | 629 | 632 | 2 / 2 / 2 / 2 | 0 / 0 / 0 |
| git_log_recent | 2,018 | 2,018 | 238 | 2 / 2 / 1 / 2 | 0 / 0 / 0 |
| git_log_history | 2,018 | 2,018 | 238 | 2 / 2 / 1 / 2 | 0 / 0 / 0 |
| git_log_explicit | 289 | 289 | 289 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| git_diff_small | 643 | 489 | 462 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| git_diff_many | 14,321 | 10,550 | 4,320 | 1 / 1 / 0 / 1 | 0 / 0 / 0 |
| git_numstat | 831 | 831 | 831 | 2 / 2 / 2 / 2 | 0 / 0 / 0 |
| git_show_content | 3,625 | 3,625 | 3,124 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| git_global_option | 167 | 167 | 80 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| ls_small | 57 | 57 | 81 | 2 / 2 / 2 / 2 | 0 / 0 / 0 |
| ls_many | 527 | 527 | 489 | 2 / 2 / 2 / 2 | 0 / 0 / 0 |
| read_small | 337 | 337 | 337 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| read_medium | 3,028 | 3,028 | 3,028 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| read_large | 11,643 | 9,385 | 11,643 | 1 / 0 / 1 / 1 | 0 / 0 / 0 |
| summary | 11,643 | 1,410 | 1,998 | 3 / 3 / 3 / 3 | 0 / 0 / 0 |
| signature | 11,643 | 1,410 | 1,998 | 3 / 3 / 3 / 3 | 0 / 0 / 0 |
| grep_narrow | 52 | 52 | 52 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| grep_context | 75 | 52 | 75 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| grep_broad | 785 | 785 | 478 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| log_repeated | 7,011 | 119 | 78 | 0 / 1 / 1 / 1 | 0 / 0 / 0 |
| log_timestamped | 16,052 | 148 | 89 | 0 / 1 / 1 / 1 | 0 / 0 / 0 |
| log_small | 41 | 41 | 41 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| log_long-lines | 7,119 | 186 | 59 | 0 / 1 / 0 / 1 | 0 / 0 / 0 |
| json_values | 12,797 | 200 | 65 | 1 / 2 / 1 / 2 | 0 / 0 / 0 |
| json_structure | 12,797 | 101 | 57 | 3 / 3 / 3 / 3 | 0 / 0 / 0 |
| pytest_pass | 116 | 73 | 38 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| pytest_fail | 964 | 927 | 474 | 3 / 3 / 3 / 3 | 1 / 1 / 1 |
| cargo_workspace | 3,872 | 1,179 | 41 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| replay_docker | 7,011 | 119 | 85 | 0 / 1 / 1 / 1 | 0 / 0 / 0 |
| replay_kubectl | 16,052 | 148 | 93 | 0 / 1 / 1 / 1 | 0 / 0 / 0 |
| replay_npm | 6,439 | 76 | 6,439 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| replay_gh | 4,224 | 4,224 | 4,224 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| replay_kubectl_json | 12,798 | 12,798 | 12,798 | 0 / 0 / 0 / 1 | 0 / 0 / 0 |

The final five cases are synthetic subprocess replays, excluded from the primary aggregate.

## Recovery

Targeted recovery knows each task's facts. Native assumes a previously saved output.
Full rereads are separate diagnostics; their token cost is excluded from the targeted sequence.

| Case | Arm | Extra calls | Response tokens | Facts after / total | Strategies |
|---|---|---:|---:|---|---|
| git_log_recent | rtk | 1 | 40 | 2 / 2 | rerun native command and filter in one shell call |
| git_log_history | rtk | 1 | 38 | 2 / 2 | rerun native command and filter in one shell call |
| git_diff_many | rtk | 1 | 33 | 1 / 1 | rerun native command and filter in one shell call |
| read_large | pi | 1 | 52 | 1 / 1 | target pi recovery file |
| log_repeated | native | 1 | 41 | 1 / 1 | target pre-saved native output (optimistic) |
| log_timestamped | native | 1 | 51 | 1 / 1 | target pre-saved native output (optimistic) |
| log_long-lines | native | 1 | 2,731 | 1 / 1 | target pre-saved native output (optimistic) |
| log_long-lines | rtk | 1 | 2,733 | 1 / 1 | rerun native command and filter in one shell call |
| json_values | native | 1 | 37 | 2 / 2 | target pre-saved native output (optimistic) |
| json_values | rtk | 1 | 36 | 2 / 2 | rerun native command and filter in one shell call |
| replay_docker | native | 1 | 41 | 1 / 1 | target pre-saved native output (optimistic) |
| replay_kubectl | native | 1 | 51 | 1 / 1 | target pre-saved native output (optimistic) |
| replay_kubectl_json | native | 1 | 37 | 1 / 1 | target pre-saved native output (optimistic) |
| replay_kubectl_json | pi | 1 | 37 | 1 / 1 | rerun native command and filter in one shell call |
| replay_kubectl_json | rtk | 1 | 37 | 1 / 1 | rerun native command and filter in one shell call |

## Warm command overhead

Paired median differences and 95% bootstrap intervals in milliseconds; 21 repetitions per case.

| Case | pi-rs minus native | RTK minus native |
|---|---:|---:|
| git_status_small | +3.14 [+2.94, +3.30] | +9.72 [+8.62, +10.33] |
| git_status_many | +3.65 [+3.30, +4.17] | +10.29 [+9.69, +10.72] |
| git_log_recent | +3.37 [+3.12, +3.95] | +8.78 [+7.63, +9.45] |
| git_log_history | +3.28 [+3.05, +3.83] | +7.88 [+7.12, +9.12] |
| git_log_explicit | +3.67 [+3.41, +4.83] | +10.15 [+8.83, +10.74] |
| git_diff_small | +4.05 [+3.50, +5.21] | +21.04 [+13.61, +27.23] |
| git_diff_many | +4.84 [+4.30, +5.87] | +16.23 [+14.78, +18.86] |
| git_numstat | +2.77 [+1.77, +3.40] | +9.43 [+7.40, +11.03] |
| git_show_content | +2.03 [+1.79, +2.34] | +9.14 [+8.70, +9.97] |
| git_global_option | +2.19 [+1.67, +2.40] | +9.54 [+8.80, +10.40] |
| ls_small | +0.40 [+0.13, +0.75] | +7.47 [+6.81, +7.96] |
| ls_many | +0.37 [-0.43, +0.67] | +13.36 [+11.89, +14.01] |
| read_small | +0.90 [+0.48, +1.08] | +6.50 [+6.09, +7.00] |
| read_medium | +0.55 [-0.00, +0.73] | +6.61 [+5.91, +7.06] |
| read_large | +1.20 [+0.95, +1.44] | +6.19 [+5.40, +7.12] |
| summary | +8.91 [+7.55, +9.48] | +8.90 [+8.16, +9.05] |
| signature | +8.66 [+8.28, +8.95] | +7.85 [+7.25, +8.76] |
| grep_narrow | +0.02 [-0.34, +0.47] | +7.84 [+7.33, +8.67] |
| grep_context | -0.10 [-0.27, +0.27] | +8.09 [+7.50, +8.47] |
| grep_broad | +0.28 [-0.27, +0.85] | +16.65 [+15.06, +18.31] |
| log_repeated | +9.25 [+8.31, +10.02] | +10.84 [+10.30, +11.77] |
| log_timestamped | +10.21 [+9.62, +10.63] | +11.68 [+10.79, +12.05] |
| log_small | +7.19 [+6.79, +7.84] | +8.94 [+8.24, +9.55] |
| log_long-lines | +9.50 [+8.91, +10.08] | +10.59 [+9.91, +11.77] |
| json_values | -0.92 [-1.15, -0.41] | +4.82 [+4.31, +5.55] |
| json_structure | -0.89 [-1.35, -0.72] | +5.50 [+4.94, +5.89] |
| pytest_pass | -2.70 [-9.11, +39.86] | +15.34 [+3.65, +23.08] |
| pytest_fail | +3.01 [-11.80, +31.32] | +29.56 [+15.01, +67.57] |
| cargo_workspace | +22.97 [+8.85, +62.96] | +41.89 [-18.99, +93.18] |
| replay_docker | +8.78 [+8.12, +9.44] | +11.55 [+10.25, +13.20] |
| replay_kubectl | +10.89 [+9.40, +11.50] | +14.01 [+11.67, +14.46] |
| replay_npm | +3.74 [+2.90, +4.15] | +10.98 [+9.71, +12.28] |
| replay_gh | +3.48 [+2.85, +3.88] | +8.93 [+8.14, +10.97] |
| replay_kubectl_json | +2.44 [+1.47, +3.32] | +10.17 [+9.23, +11.38] |

## Scope and mappings

- RTK summary/signature intent maps to `rtk read --level aggressive`; `rtk summary` runs a command.
- RTK grep gets the native rg arguments, including explicit context flags.
- RTK JSON structure intent maps to `rtk json --keys-only`.
- Equivalent unquoted `total: 500` and `cargo test: N passed` count as the corresponding facts for every arm.
- Direct-command RTK measurements suppress its missing-hook installation warning, disable telemetry, and retain default tracking and SQLite recovery.
- Direct timings exclude hook invocation and model decisions. The separate Codex matrix includes the installed integration.
- Command totals exclude instruction documents; provider input usage in the model experiment includes integration overhead.
