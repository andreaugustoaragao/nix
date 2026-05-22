# pi-rs token compression

When invoking shell commands, prefer the `pi-rs`-compressed equivalents
for these common tools. They subprocess the real tool, compress the
output, and forward the original exit code. Token savings: typically 60–90%
on cargo/pytest, 80% on git/ls, 80–90% on docker/kubectl logs.

| Run this | Instead of | Why |
|----------|------------|-----|
| `pi-rs git ...` | `git ...` | status defaults to `--short`, log to `--oneline -n 20`, diff/show truncated |
| `pi-rs cargo ...` | `cargo ...` | huge build/test outputs truncated with tee log |
| `pi-rs gh ...` | `gh ...` | PR/issue listings truncated |
| `pi-rs npm ...` / `pi-rs pnpm ...` / `pi-rs yarn ...` | `npm` / `pnpm` / `yarn ...` | install progress stripped, tee for full logs |
| `pi-rs pytest ...` | `pytest ...` | quiet mode by default; failures preserved |
| `pi-rs docker ...` / `pi-rs kubectl ...` | `docker` / `kubectl ...` | logs deduped (collapses repeated lines) |
| `pi-rs read FILE` | `cat FILE` | head+tail with tee log; `--level signature` for symbol-only |
| `pi-rs ls [PATH]` | `ls ...` | files vs dirs grouped with counts |
| `pi-rs find PATTERN [PATH]` | `find ...` | results grouped by parent directory |
| `pi-rs grep PATTERN [PATH]` | `rg` / `grep ...` | hashline-anchored matches grouped by file |
| `pi-rs json [FILE]` | `jq` | pretty-print or `--structure` for keys-only |
| `pi-rs log FILE` | `cat` / `tail FILE` | repeated lines collapse to `(×N)` form |

## Tee recovery for truncated output

When a wrapper truncates its output you'll see a line like:

    ... [N lines elided — full output: ~/.local/share/pi-rs/tee/<ts>_<cmd>.log]

That path holds the raw unfiltered output. Read it with `pi-rs read <path>`
or plain `cat` if you need the full payload — don't re-run the original
command.

## When to skip pi-rs

For interactive human-facing commands (e.g., reading colorized output
yourself), the raw tool is fine. The pi-rs wrappers exist to reduce the
*model's* context usage, not the user's terminal experience.
