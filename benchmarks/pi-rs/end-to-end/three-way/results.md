# Fresh three-arm Codex comparison

45 sessions on five fixed fixtures, requested `gpt-6.1-sol` / `medium`.

| Metric | Native | pi-rs 0.2.0 | RTK 0.51.0 |
|---|---:|---:|---:|
| successes | 15 | 15 | 15 |
| input_tokens | 583,172 | 484,777 | 666,064 |
| cached_input_tokens | 364,498 | 283,577 | 461,546 |
| uncached_input_tokens | 218,674 | 201,200 | 204,518 |
| output_tokens | 3,441 | 2,684 | 3,509 |
| seconds | 160.0 | 132.8 | 172.5 |
| command_count | 38 | 39 | 55 |
| command_output_bytes | 200,063 | 80,974 | 105,322 |
| rtk_hook_rewrite_count | 0 | 0 | 48 |
| rtk_hook_skip_count | 0 | 0 | 3 |
| recovery_command_count | 0 | 4 | 0 |
| agent_instruction_read_count | 0 | 0 | 15 |

| Task | Native input | pi-rs input | RTK input | Correct native/pi/RTK |
|---|---:|---:|---:|---|
| noisy_log | 88,162 | 69,561 | 122,738 | 3/3/3 |
| config_diff | 173,998 | 148,530 | 180,591 | 3/3/3 |
| source_lookup | 112,231 | 88,034 | 126,607 | 3/3/3 |
| cargo_failure | 107,521 | 71,444 | 100,313 | 3/3/3 |
| recent_history | 101,260 | 107,208 | 135,815 | 3/3/3 |

| Comparison | Total-input reduction | Uncached-input reduction | Input-saving pairs |
|---|---:|---:|---:|
| pi_vs_stock | 16.87% | 7.99% | 9/15 |
| rtk_vs_stock | -14.21% | 6.47% | 4/15 |
| rtk_vs_pi | -37.40% | -1.65% | 1/15 |

Positive reduction means the named treatment used less. Timing is descriptive and includes provider latency. RTK hook rewrite counts include intact parsed audit records; concurrent audit-log corruption can make them lower bounds. See ../THREE_WAY.md for integration behavior, protocol details, and limitations.
