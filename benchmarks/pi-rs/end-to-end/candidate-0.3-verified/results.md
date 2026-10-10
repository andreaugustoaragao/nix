# Fresh three-arm Codex comparison

45 sessions on five fixed fixtures, requested `gpt-6.1-sol` / `medium`.

| Metric | Native | pi-rs 0.3.0 | rtk 0.51.0 |
|---|---:|---:|---:|
| successes | 15 | 15 | 15 |
| input_tokens | 640,993 | 533,247 | 671,919 |
| cached_input_tokens | 421,242 | 328,052 | 471,267 |
| uncached_input_tokens | 219,751 | 205,195 | 200,652 |
| output_tokens | 3,303 | 3,003 | 3,348 |
| seconds | 179.4 | 164.2 | 190.4 |
| command_count | 40 | 41 | 54 |
| command_output_bytes | 201,107 | 139,814 | 92,942 |
| rtk_hook_rewrite_count | 0 | 0 | 49 |
| rtk_hook_skip_count | 0 | 0 | 1 |
| recovery_command_count | 0 | 3 | 0 |
| agent_instruction_read_count | 0 | 0 | 15 |

| Task | Native input | pi-rs input | RTK input | Correct native/pi/RTK |
|---|---:|---:|---:|---|
| noisy_log | 124,292 | 67,245 | 122,522 | 3/3/3 |
| config_diff | 171,569 | 177,298 | 162,137 | 3/3/3 |
| source_lookup | 136,961 | 105,541 | 151,066 | 3/3/3 |
| cargo_failure | 107,641 | 79,644 | 100,485 | 3/3/3 |
| recent_history | 100,530 | 103,519 | 135,709 | 3/3/3 |

| Comparison | Total-input reduction | Uncached-input reduction | Input-saving pairs |
|---|---:|---:|---:|
| pi_vs_stock | 16.81% | 6.62% | 11/15 |
| rtk_vs_stock | -4.82% | 8.69% | 6/15 |
| rtk_vs_pi | -26.01% | 2.21% | 3/15 |

Positive reduction means the named treatment used less. Timing is descriptive and includes provider latency. RTK hook rewrite counts include intact parsed audit records; concurrent audit-log corruption can make them lower bounds. See ../THREE_WAY.md for integration behavior, protocol details, and limitations.
