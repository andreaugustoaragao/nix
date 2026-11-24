# pstack in Codex

Apply this guide whenever any pstack skill runs in Codex (`codex`,
`codex-openai`, or `codex-webai`). It is the authoritative source for execution
policy, subagent dispatch, model selection, and family classification in Codex.
Preserve project instructions and their rules for delegation, review, and
commits. These preferences do not enable autonomous work or change the parent
model.

## Execution policy

Use relevant pstack coding, design, writing, and verification guidance.

Invoking `poteto-mode` does not authorize automatic workflow routing, agent
panels, or delegation. This restriction also applies to skills that pstack
invokes indirectly.

Default to direct implementation by the current agent. Use multi-agent
workflows only when explicitly requested or authorized for the task.

When delegation is authorized:

- Delegate complete, independent pieces of work with clear ownership.
- Reuse the implementation agent for corrections and follow-ups.
- Use a fresh reviewer when independent review is warranted.
- Do not launch another agent solely because a fix or retry is needed.

Keep approved design decisions closed unless new evidence invalidates them.

Repeat tests or reviews only for changed behavior, new evidence, or missing
required coverage. Reuse valid passing evidence.

These rules override conflicting pstack workflow and delegation defaults.
Preserve project-required verification and explicit user instructions.

## Model routing (OpenAI only)

Budget: `large` (`xhigh` starting reasoning effort for judgment/panels, `high`
for routine code/exploration).

| Pstack role | `codex-openai` (ChatGPT) | `codex-webai` (LiteLLM) |
| --- | --- | --- |
| `feature, refactoring` | `gpt-6.1-sol` | `gpt-6.2-sol` |
| `bug-fix` | `gpt-6.1-sol` | `gpt-6.2-sol` |
| `perf-issue` | `gpt-6.1-sol` | `gpt-6.2-sol` |
| `hillclimb` | `gpt-6.1-sol` | `gpt-6.2-sol` |
| `judgment and prose` | `gpt-6-astra` | `gpt-6.2-astra` |
| `hardest tasks` | `gpt-6-astra` | `gpt-6.2-astra` |
| `how explorer` | `gpt-6.1-sol` | `gpt-6.2-sol` |
| `how explainer` | `gpt-6-astra` | `gpt-6.2-astra` |
| `why investigators` | `gpt-6.1-sol` | `gpt-6.2-sol` |
| `why synthesizer` | `gpt-6-astra` | `gpt-6.2-astra` |
| `reflect tooling` | `gpt-6.1-sol` | `gpt-6.2-sol` |
| `reflect judgment, divergent, synthesizer` | `gpt-6-astra` | `gpt-6.2-astra` |
| `arena runners` | `gpt-6-astra`, `gpt-6.1-sol` | `gpt-6.2-astra`, `gpt-6.2-sol` |
| `arena cross-judge pool` | *(none — OpenAI-only; see below)* | *(none — OpenAI-only; see below)* |
| `swarm workers` | `gpt-6.1-sol` | `gpt-6.2-sol` |
| `architect runners` | `gpt-6-astra`, `gpt-6.1-sol` | `gpt-6.2-astra`, `gpt-6.2-sol` |
| `interrogate reviewers` | `gpt-6-astra`, `gpt-6.1-sol` | `gpt-6.2-astra`, `gpt-6.2-sol` |

Provider split: ChatGPT `codex-openai` accounts reject `gpt-6.2-*` IDs, so use
the `codex-openai` column on native OpenAI auth and the `codex-webai` column on
LiteLLM.

Allowed pstack family in Codex: **`openai`** only. The table's model IDs are
verified against `codex debug models`; note that `spawn_agent`'s tool
description may truncate its listed models under `codex-webai`, so pass the
table's exact model ID directly rather than rejecting it based on the truncated
schema list. Pass `model` and `reasoning_effort` separately (never append
effort or speed suffixes to a model ID, and omit `reasoning_effort` on
`codex-webai` `gpt-6.2-*` if the provider advertises no explicit effort levels).
If the runtime actually rejects a model, pause only the affected delegation and
report the exact error. Only omit `model` (inheriting the parent) when the
parent itself is an `openai` model.

### Model diversity vs. family diversity

Classify model families by prefix: `gpt-*`, `o1-*`, `o3-*`, `o4-*`, `codex-*`
all belong to the `openai` family.

Because both Astra (`gpt-6-astra` / `gpt-6.2-astra`) and Sol (`gpt-6.1-sol` /
`gpt-6.2-sol`) are `openai` models:

- Multi-runner panels (`arena runners`, `architect runners`,
  `interrogate reviewers`) provide **within-OpenAI model diversity**, not
  cross-family diversity.
- For **Arena Phase C (Cross-judge)** and any other step that requires a
  different model family from an OpenAI parent, **no qualifying non-OpenAI
  family is available on either Codex route**. Skip Phase C, pick the base alone
  in Phase D, and report that no cross-family judge was available — never treat
  another GPT model as satisfying a cross-family check.

## Subagent dispatch

Use Codex's native agent tools (`spawn_agent`) for pstack `Task` calls. With
explicit model or effort overrides, use a supported limited-history or
no-history fork, and supply the task, constraints, file paths, and required
role instructions from `<pstack>/agents/poteto-agent.md` (do not pass
Cursor-only `subagent_type` names like `poteto-agent` or `generalPurpose`).
Skip Cursor-only features (Automations, Bugbot, cloud agents, `/loop`) with a
one-line note and continue. Follow the session's concurrency limit.

## Configuration ownership

This guide is Nix-managed in
`~/projects/personal/nix/home/cli/pstack/harness-codex.md` (packaged by
`home/cli/pstack.nix`). Do not write `~/.cursor/rules/pstack-models.mdc`, edit
Nix store files, or overwrite runtime config. Validate the Nix source and
report activation as pending until it has actually run; new chats load the
updated skill after activation.
