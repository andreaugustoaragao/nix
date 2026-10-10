# Verified isolated Codex A/B results

30 sessions; requested model `gpt-6.1-sol`, reasoning `medium`.

| Metric (15 sessions per arm) | Stock | pi-rs |
|---|---:|---:|
| successes | 15 | 15 |
| input_tokens | 603,610 | 463,965 |
| cached_input_tokens | 392,910 | 272,025 |
| uncached_input_tokens | 210,700 | 191,940 |
| output_tokens | 2,907 | 2,482 |
| seconds | 173.6 | 129.7 |
| command_count | 37 | 37 |
| command_output_bytes | 194,415 | 50,758 |
| pi_command_count | 0 | 33 |
| recovery_command_count | 0 | 3 |

| Task | Stock input | pi-rs input | Input reduction | Uncached reduction |
|---|---:|---:|---:|---:|
| noisy_log | 76,816 | 69,638 | 9.3% | -5.5% |
| config_diff | 178,339 | 115,937 | 35.0% | 33.5% |
| source_lookup | 125,956 | 87,995 | 30.1% | -10.1% |
| cargo_failure | 121,994 | 71,566 | 41.3% | 12.4% |
| recent_history | 100,505 | 118,829 | -18.2% | -6.8% |

Overall input reduction: 23.13%. Uncached input reduction: 8.90%. Input savings in 9/15 pairs.

Descriptive paired bootstrap interval: [14.00%, 30.40%]. This measures variability of repeated sessions on these fixed fixtures; it does not establish a population-wide benefit.

See ../README.md for isolation, protocol exclusions, source limitations, and reproduction.
