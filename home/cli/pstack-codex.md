# Pstack in Codex

Apply this guide when a pstack skill is invoked in Codex. It controls execution
and overrides the bundled Cursor model defaults for Codex only. Preserve
project instructions and their rules for delegation, review, and commits.
These preferences do not enable autonomous work or change the parent model.

## Execution policy

Use relevant pstack coding, design, writing, and verification guidance.

Invoking poteto-mode does not authorize automatic workflow routing,
agent panels, or delegation. This restriction also applies to skills
that pstack invokes indirectly.

Default to direct implementation by the current agent. Use multi-agent
workflows only when explicitly requested or authorized for the task.

When delegation is authorized:

- Delegate complete, independent pieces of work with clear ownership.
- Reuse the implementation agent for corrections and follow-ups.
- Use a fresh reviewer when independent review is warranted.
- Do not launch another agent solely because a fix or retry is needed.

Keep approved design decisions closed unless new evidence invalidates them.

Repeat tests or reviews only for changed behavior, new evidence, or
missing required coverage. Reuse valid passing evidence.

These rules override conflicting pstack workflow and delegation defaults.
Preserve project-required verification and explicit user instructions.

## Authorized delegation and model setup

Budget: large (xhigh starting reasoning effort).

| Pstack role | Model |
|---|---|
| feature, refactoring | gpt-6-sol |
| bug-fix | gpt-6-sol |
| perf-issue | gpt-6-sol |
| hillclimb | gpt-6-sol |
| judgment and prose | gpt-6-astra |
| hardest tasks | gpt-6-astra |
| how explorer | gpt-6-sol |
| how explainer | gpt-6-astra |
| why investigators | gpt-6-sol |
| why synthesizer | gpt-6-astra |
| reflect tooling | gpt-6-sol |
| reflect judgment, divergent, synthesizer | gpt-6-astra |
| arena runners | gpt-6-astra, gpt-6-sol |
| arena cross-judge pool | gpt-6-astra, gpt-6-sol |
| swarm workers | gpt-6-sol |
| architect runners | gpt-6-astra, gpt-6-sol |
| interrogate reviewers | gpt-6-astra, gpt-6-sol |

Provider split: the table above lists native ChatGPT `codex-openai` model
IDs (`gpt-6-astra`, `gpt-6-sol`), because ChatGPT Codex accounts reject
`gpt-6.2-*`. When running via `codex-webai` (LiteLLM), use `gpt-6.2-astra`
in place of `gpt-6-astra` and `gpt-6.2-sol` in place of `gpt-6-sol`.

Validate models and reasoning levels against the current session's agent
tool before spawning. Pass model and reasoning effort separately; never
append effort or speed suffixes to a model name. If a configured model is
unavailable, ask for a replacement and pause only the affected delegation.
Do not substitute another version silently. The aliases inherit-parent and
auto omit both overrides and retain the parent model and effort.

Use Codex's available agent tools for pstack Task calls. With explicit model
or effort overrides, use a supported limited-history or no-history fork,
and supply the task, constraints, file paths, and required role instructions.
Resolve bundled role prompts from the installed pstack agents directory;
do not pass Cursor-only role names as native Codex agent types. Each panel
entry runs one agent; the cross-judge pool selects one different model from
the parent when available. These are different OpenAI models, not a
cross-provider panel. Follow the session's concurrency limit.

When setup-pstack is invoked in Codex, use this table as the current mapping
and the session's agent tool as the source of available models and efforts.
Offer small (medium), medium (high), large (xhigh), or unlimited (max).
These are reasoning presets, not spending caps. Preserve aliases and role
choices when changing the budget. If an effort is unsupported, offer the
highest supported level at or below it. Show the complete proposed mapping
and confirm changes before saving, as the setup skill requires.

This guide is Nix-managed. Persist setup changes in
`~/projects/personal/nix/home/cli/pstack-codex.md` (packaged by
`home/cli/pstack.nix`). Preserve unrelated source changes. Do not write Cursor
rules, edit Nix store files, or overwrite runtime config. Validate the Nix
source and report activation as pending until it has actually run; new chats
load the updated skill after activation.
