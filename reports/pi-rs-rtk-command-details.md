# Native / pi-rs / RTK: command details

Fresh measurements on identical regenerated fixtures. N = native, P = pi-rs 0.2.0, R = RTK 0.51.0.

Tokens use o200k_base after the same Codex 10,000 approximate-token cap, with fixed execution headers.

| Case | N tokens | P tokens | R tokens | Facts N / P / R / total | Exit N / P / R |
|---|---:|---:|---:|---|---|
| git_status_small | 167 | 77 | 80 | 2 / 2 / 2 / 2 | 0 / 0 / 0 |
| git_status_many | 995 | 424 | 632 | 2 / 1 / 2 / 2 | 0 / 0 / 0 |
| git_log_recent | 2,018 | 289 | 238 | 2 / 2 / 1 / 2 | 0 / 0 / 0 |
| git_log_history | 2,018 | 289 | 238 | 2 / 0 / 1 / 2 | 0 / 0 / 0 |
| git_log_explicit | 289 | 289 | 289 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| git_diff_small | 643 | 599 | 462 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| git_diff_many | 14,321 | 507 | 4,320 | 1 / 0 / 0 / 1 | 0 / 0 / 0 |
| git_numstat | 831 | 831 | 831 | 2 / 2 / 2 / 2 | 0 / 0 / 0 |
| git_show_content | 3,625 | 3,625 | 3,124 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| git_global_option | 167 | 167 | 80 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| ls_small | 57 | 79 | 81 | 2 / 2 / 2 / 2 | 0 / 0 / 0 |
| ls_many | 527 | 643 | 489 | 2 / 2 / 2 / 2 | 0 / 0 / 0 |
| read_small | 337 | 337 | 337 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| read_medium | 3,028 | 1,507 | 3,028 | 1 / 0 / 1 / 1 | 0 / 0 / 0 |
| read_large | 11,643 | 2,064 | 11,643 | 1 / 0 / 1 / 1 | 0 / 0 / 0 |
| summary | 11,643 | 1,663 | 1,998 | 3 / 3 / 3 / 3 | 0 / 0 / 0 |
| signature | 11,643 | 1,663 | 1,998 | 3 / 3 / 3 / 3 | 0 / 0 / 0 |
| grep_narrow | 52 | 154 | 52 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| grep_context | 75 | 154 | 75 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| grep_broad | 785 | 3,647 | 478 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| log_repeated | 7,011 | 99 | 78 | 0 / 1 / 1 / 1 | 0 / 0 / 0 |
| log_timestamped | 16,052 | 3,269 | 89 | 0 / 0 / 1 / 1 | 0 / 0 / 0 |
| log_small | 41 | 41 | 41 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| log_long-lines | 7,119 | 7,119 | 59 | 0 / 0 / 0 / 1 | 0 / 0 / 0 |
| json_values | 12,797 | 921 | 65 | 1 / 1 / 1 / 2 | 0 / 0 / 0 |
| json_structure | 12,797 | 73 | 57 | 3 / 3 / 3 / 3 | 0 / 0 / 0 |
| pytest_pass | 113 | 48 | 38 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| pytest_fail | 961 | 560 | 474 | 3 / 3 / 3 / 3 | 1 / 1 / 1 |
| cargo_workspace | 4,088 | 966 | 41 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| replay_docker | 7,011 | 99 | 85 | 0 / 1 / 1 / 1 | 0 / 0 / 0 |
| replay_kubectl | 16,052 | 1,270 | 93 | 0 / 0 / 1 / 1 | 0 / 0 / 0 |
| replay_npm | 6,439 | 75 | 6,439 | 1 / 1 / 1 / 1 | 0 / 0 / 0 |
| replay_gh | 4,224 | 1,748 | 4,224 | 1 / 0 / 1 / 1 | 0 / 0 / 0 |
| replay_kubectl_json | 12,798 | 12,798 | 12,798 | 0 / 0 / 0 / 1 | 0 / 0 / 0 |

The final five cases are synthetic subprocess replays, excluded from the primary aggregate.

## Recovery

Targeted recovery knows each task's facts. Native assumes a previously saved output.
Full rereads are separate diagnostics; their token cost is excluded from the targeted sequence.

| Case | Arm | Extra calls | Response tokens | Facts after / total | Strategies |
|---|---|---:|---:|---|---|
| git_status_many | pi | 1 | 33 | 2 / 2 | target pi tee file |
| git_log_recent | rtk | 1 | 40 | 2 / 2 | rerun native command and filter in one shell call |
| git_log_history | pi | 1 | 38 | 2 / 2 | rerun native command and filter in one shell call |
| git_log_history | rtk | 1 | 38 | 2 / 2 | rerun native command and filter in one shell call |
| git_diff_many | pi | 1 | 33 | 1 / 1 | target pi tee file |
| git_diff_many | rtk | 1 | 33 | 1 / 1 | rerun native command and filter in one shell call |
| read_medium | pi | 1 | 36 | 1 / 1 | target pi tee file |
| read_large | pi | 1 | 52 | 1 / 1 | target pi tee file |
| log_repeated | native | 1 | 41 | 1 / 1 | target pre-saved native output (optimistic) |
| log_timestamped | native | 1 | 51 | 1 / 1 | target pre-saved native output (optimistic) |
| log_timestamped | pi | 1 | 51 | 1 / 1 | target pi tee file |
| log_long-lines | native | 1 | 2,731 | 1 / 1 | target pre-saved native output (optimistic) |
| log_long-lines | pi | 1 | 2,733 | 1 / 1 | rerun native command and filter in one shell call |
| log_long-lines | rtk | 1 | 2,733 | 1 / 1 | rerun native command and filter in one shell call |
| json_values | native | 1 | 37 | 2 / 2 | target pre-saved native output (optimistic) |
| json_values | pi | 1 | 37 | 2 / 2 | target pi tee file |
| json_values | rtk | 1 | 36 | 2 / 2 | rerun native command and filter in one shell call |
| replay_docker | native | 1 | 41 | 1 / 1 | target pre-saved native output (optimistic) |
| replay_kubectl | native | 1 | 51 | 1 / 1 | target pre-saved native output (optimistic) |
| replay_kubectl | pi | 1 | 51 | 1 / 1 | target pi tee file |
| replay_gh | pi | 1 | 54 | 1 / 1 | target pi tee file |
| replay_kubectl_json | native | 1 | 37 | 1 / 1 | target pre-saved native output (optimistic) |
| replay_kubectl_json | pi | 1 | 37 | 1 / 1 | rerun native command and filter in one shell call |
| replay_kubectl_json | rtk | 1 | 37 | 1 / 1 | rerun native command and filter in one shell call |

## Warm command overhead

Paired median differences and 95% bootstrap intervals in milliseconds; 21 repetitions per case.

| Case | pi-rs minus native | RTK minus native |
|---|---:|---:|
| git_status_small | +1.67 [+1.32, +2.31] | +4.95 [+4.70, +5.52] |
| git_status_many | +2.23 [+1.87, +2.63] | +5.64 [+4.91, +6.53] |
| git_log_recent | +1.67 [+1.51, +1.88] | +3.90 [+3.73, +4.31] |
| git_log_history | +1.97 [+1.60, +2.17] | +4.05 [+3.87, +4.53] |
| git_log_explicit | +1.86 [+1.63, +2.44] | +3.80 [+3.71, +4.23] |
| git_diff_small | +1.99 [+1.84, +2.20] | +4.98 [+4.67, +5.49] |
| git_diff_many | +2.24 [+1.89, +2.48] | +8.13 [+7.21, +8.38] |
| git_numstat | +1.11 [+0.88, +1.33] | +4.88 [+4.25, +5.82] |
| git_show_content | +1.12 [+1.05, +1.34] | +5.51 [+5.01, +5.88] |
| git_global_option | +1.07 [+0.96, +1.58] | +5.32 [+5.15, +5.62] |
| ls_small | +0.18 [-0.47, +0.32] | +4.53 [+4.16, +4.80] |
| ls_many | +0.32 [+0.17, +0.52] | +9.45 [+8.47, +10.05] |
| read_small | +0.43 [+0.40, +0.52] | +4.02 [+3.10, +4.84] |
| read_medium | +0.32 [+0.14, +0.55] | +3.49 [+2.92, +4.06] |
| read_large | +0.16 [+0.04, +0.37] | +3.11 [+2.73, +3.85] |
| summary | +4.69 [+4.57, +5.04] | +3.86 [+3.51, +4.14] |
| signature | +4.52 [+3.83, +4.88] | +4.15 [+3.24, +4.36] |
| grep_narrow | -0.07 [-0.16, +0.10] | +4.18 [+3.77, +4.93] |
| grep_context | -0.07 [-0.22, +0.07] | +4.08 [+3.74, +4.54] |
| grep_broad | -0.00 [-0.14, +0.14] | +6.45 [+6.12, +6.88] |
| log_repeated | +0.54 [+0.34, +0.67] | +4.82 [+4.59, +5.36] |
| log_timestamped | +0.66 [+0.49, +0.94] | +5.55 [+4.95, +6.02] |
| log_small | +0.08 [-0.61, +0.33] | +3.73 [+3.13, +4.38] |
| log_long-lines | +0.86 [+0.61, +1.05] | +5.41 [+4.59, +5.51] |
| json_values | -0.76 [-0.91, -0.63] | +2.72 [+2.36, +3.16] |
| json_structure | -1.02 [-1.17, -0.79] | +2.25 [+2.08, +2.94] |
| pytest_pass | -0.40 [-8.27, +8.39] | -1.05 [-6.24, +7.73] |
| pytest_fail | +6.37 [+1.50, +11.28] | +12.52 [+6.84, +15.46] |
| cargo_workspace | +1.57 [-2.18, +6.71] | +5.36 [-1.07, +7.49] |
| replay_docker | +2.27 [+1.67, +3.17] | +6.01 [+5.25, +6.62] |
| replay_kubectl | +2.70 [+1.88, +3.27] | +6.86 [+6.30, +7.66] |
| replay_npm | +2.40 [+1.73, +2.67] | +4.75 [+3.61, +5.29] |
| replay_gh | +2.44 [+1.41, +3.19] | +4.92 [+3.70, +5.66] |
| replay_kubectl_json | +1.15 [+0.54, +1.71] | +4.27 [+3.32, +5.00] |

## Scope and mappings

- RTK summary/signature intent maps to `rtk read --level aggressive`; `rtk summary` runs a command.
- RTK grep gets the native rg arguments, including explicit context flags.
- RTK JSON structure intent maps to `rtk json --keys-only`.
- Equivalent unquoted `total: 500` and `cargo test: N passed` count as the corresponding facts for every arm.
- Direct-command RTK measurements suppress its missing-hook installation warning, disable telemetry, and retain default tracking and SQLite recovery.
- Direct timings exclude hook invocation and model decisions. The separate Codex matrix includes the installed integration.
- Command totals exclude instruction documents; provider input usage in the model experiment includes integration overhead.
