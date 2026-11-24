# pstack in OMP

Apply this guide whenever any pstack skill runs in OMP (`oh-my-pi`). It is the
authoritative source for tool mapping, subagent dispatch, model selection, and
model-family classification in OMP. Preserve project instructions and rules for
delegation, review, and commits.

## Tools and subagents

| pstack / Cursor concept | OMP equivalent |
| --- | --- |
| `Task` | `task` tool (batched `tasks[]` with shared `context`, per-item `task`, `solutionSpace`, optional `agent` and `model`). |
| `subagent_type: "poteto-agent"` | `agent: "task"` (default, omit `agent`) and include `<pstack>/agents/poteto-agent.md` instructions/path in `context` or `task`. |
| `subagent_type: "generalPurpose"` (read-write) | `agent: "task"` (omit `agent`). |
| `subagent_type: "generalPurpose"` + `readonly: true` | `agent: "scout"` (read-only) with explicit `model` when the role names one. |
| `comment-sicko` | `agent: "task"` with `<pstack>/agents/comment-sicko.md` instructions. |
| `AskQuestion` | `ask` tool (plain semantic HTML `<form>`). |
| Open a todolist | `todo` tool. |
| Run another pstack skill | `read skill://<name>` (e.g. `skill://arena`, `skill://principle-model-the-domain`). |
| `environment: "cloud"` | Local isolated git worktree (`git worktree add`); OMP has no Cursor cloud agents. |
| `run_in_background: true` | `task` batches already execute asynchronously; never poll. |
| Cursor Automations / Bugbot / `/loop` / built-in PR tool | Skip Automations and `/loop` with a one-line `Skipped in OMP: <step>. <reason>.` note; use `gh` / `github` tool for PRs and review threads. |

## Model routing (Gemini + OpenAI)

OMP is configured with `task.perCallModel = "on"`. Every per-call `model` below
is an exact `provider/model:level` selector granted by operator `modelRoles` in
`~/.omp/agent/config.yml`.

Important OMP constraint: never pass a per-call `model` alongside an `agent`
that has a `task.agentModelOverrides` entry (`reviewer`, `sonic`), because OMP
rejects conflicting per-call overrides. Dispatch per-model pstack workers with
`agent: "task"` (or `"scout"` for read-only exploration).

Budget: `large` (`xhigh` for judgment/panels, `high` for code/explorers).

| Pstack role | OMP `model` selector(s) |
| --- | --- |
| `feature, refactoring` | `litellm/gpt-6.2-sol:high` |
| `bug-fix` | `litellm/gpt-6.2-sol:high` |
| `perf-issue` | `litellm/gpt-6.2-sol:high` |
| `hillclimb` | `litellm/gpt-6.2-sol:high` |
| `judgment and prose` | `litellm/gpt-6.2-astra:xhigh` |
| `hardest tasks` | `litellm/gpt-6.2-astra:xhigh` |
| `how explorer` | `litellm/gemini-4-hydrogen:high` |
| `how explainer` | `litellm/gpt-6.2-astra:xhigh` |
| `why investigators` | `litellm/gemini-4-hydrogen:high` |
| `why synthesizer` | `litellm/gpt-6.2-astra:xhigh` |
| `reflect tooling` | `litellm/gemini-4-hydrogen:high` |
| `reflect judgment, divergent, synthesizer` | `litellm/gpt-6.2-astra:xhigh` |
| `arena runners` | `litellm/gpt-6.2-astra:xhigh`, `litellm/gemini-4-neon:xhigh` |
| `arena cross-judge pool` | `litellm/gpt-6.2-astra:xhigh`, `litellm/gemini-4-neon:xhigh` |
| `swarm workers` | `litellm/gemini-4-hydrogen:high` |
| `architect runners` | `litellm/gpt-6.2-astra:xhigh`, `litellm/gemini-4-neon:xhigh` |
| `interrogate reviewers` | `litellm/gpt-6.2-astra:xhigh`, `litellm/gemini-4-neon:xhigh` |

### Model families and cross-family judging

Strip any `provider/` prefix (e.g. `litellm/`, `cursor/`) and trailing `:effort`
suffix before classifying family:

- `openai`: `gpt-*`, `o1-*`, `o3-*`, `o4-*`, `codex-*`
- `gemini`: `gemini-*`
- `grok`: `grok-*`, `cursor-grok-*`
- `composer`: `composer-*`
- `claude`: `claude-*`

OMP panels pair `openai` (`litellm/gpt-6.2-astra:xhigh`) and `gemini`
(`litellm/gemini-4-neon:xhigh`). For Arena Phase C cross-judging:

- A `gemini` parent (default `litellm/gemini-4-neon:high`) selects
  `litellm/gpt-6.2-astra:xhigh`.
- An `openai` parent (`litellm/gpt-6.2-*`) selects `litellm/gemini-4-neon:xhigh`.

Allowed pstack families in OMP: **`openai`** and **`gemini`** only.

If OMP rejects a per-call `model` (e.g. missing operator grant or unavailable
endpoint), report the exact error. Only retry without `model` (inheriting the
parent) when the parent model itself belongs to an allowed OMP pstack family
(`openai` or `gemini`) and no cross-family requirement is violated; otherwise
drop or fail the seat and report it. Never treat a same-family model as a
cross-family judge.

## Configuration ownership

This guide is Nix-managed in
`~/projects/personal/nix/home/cli/pstack/harness-omp.md` (and
`home/cli/omp.nix`). Do not write `~/.cursor/rules/pstack-models.mdc` or edit
Nix store files. Update the Nix source and activate to change role mappings.
