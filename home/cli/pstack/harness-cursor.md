# pstack in Cursor

Apply this guide whenever any pstack skill runs in Cursor or `cursor-agent`. It
is the authoritative source for model selection and family classification in
Cursor, replacing upstream `claude-opus-5-5-*` defaults (Claude models are not
entitled in this Cursor account).

## Subagents

- Keep native `subagent_type: "poteto-agent"` (loaded via `--plugin-dir`) for
  playbook code/helper delegates and `subagent_type: "generalPurpose"` where
  routed skills specify it.
- Keep `run_in_background: true` and agent mode (`readonly: false`) when MCP
  access is needed.

## Model routing (Gemini + Grok)

Cursor's `Task` subagent tool accepts a narrower slug set than top-level
`cursor-agent --list-models`. Every slug below is verified directly against
Cursor's live `Task` subagent allowlist (`gemini-4-neon-high`,
`gemini-4-carbon-high`, `grok-4.7-xhigh`, `cursor-grok-4.6-high-fast`). Do not
use unaccepted slugs such as `gemini-4-neon-xhigh`, `grok-4.7-high-fast`, or
`grok-4.7-xhigh-fast` in `Task` calls.

Allowed pstack families in Cursor: **`gemini`** and **`grok`** only.

| Pstack role | Cursor `Task` `model` slug(s) |
| --- | --- |
| `feature, refactoring` | `grok-4.7-xhigh` |
| `bug-fix` | `grok-4.7-xhigh` |
| `perf-issue` | `grok-4.7-xhigh` |
| `hillclimb` | `grok-4.7-xhigh` |
| `judgment and prose` | `gemini-4-neon-high` |
| `hardest tasks` | `gemini-4-neon-high` |
| `how explorer` | `cursor-grok-4.6-high-fast` |
| `how explainer` | `gemini-4-neon-high` |
| `why investigators` | `cursor-grok-4.6-high-fast` |
| `why synthesizer` | `gemini-4-neon-high` |
| `reflect tooling` | `cursor-grok-4.6-high-fast` |
| `reflect judgment, divergent, synthesizer` | `gemini-4-neon-high` |
| `arena runners` | `gemini-4-neon-high`, `grok-4.7-xhigh` |
| `arena cross-judge pool` | `gemini-4-neon-high`, `grok-4.7-xhigh` |
| `swarm workers` | `cursor-grok-4.6-high-fast` |
| `architect runners` | `gemini-4-neon-high`, `grok-4.7-xhigh` |
| `interrogate reviewers` | `gemini-4-neon-high`, `grok-4.7-xhigh` |

### Model families and cross-family judging

Classify model families by prefix:

- `gemini`: `gemini-*`
- `grok`: `grok-*`, `cursor-grok-*`
- `composer`: `composer-*`
- `openai`: `gpt-*`, `o1-*`, `o3-*`, `o4-*`, `codex-*`
- `claude`: `claude-*`

Cursor panels pair `gemini` (`gemini-4-neon-high`) and `grok`
(`grok-4.7-xhigh`). For Arena Phase C cross-judging:

- A `gemini` parent selects `grok-4.7-xhigh`.
- A `grok`, `composer`, or any non-Gemini parent selects `gemini-4-neon-high`.

If the `Task` tool rejects a configured slug, fall back to the closest valid
slug in the same family from the error output and say so. Only omit `model` (to
inherit the parent) when the parent itself is known to belong to an allowed
Cursor pstack family (`gemini` or `grok`) and no cross-family constraint is
violated; do **not** fall back to an Auto-selected or `openai`/`composer`
parent — drop or fail the seat and report it instead.

## Configuration ownership

This guide is Nix-managed in
`~/projects/personal/nix/home/cli/pstack/harness-cursor.md` (packaged by
`home/cli/pstack.nix`). Do not write an always-on
`~/.cursor/rules/pstack-models.mdc` file (it would leak pstack instructions into
non-pstack turns). Update the Nix source and activate to change role mappings.
