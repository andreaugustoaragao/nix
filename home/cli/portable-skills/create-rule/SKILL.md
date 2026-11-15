---
name: create-rule
description: Create or revise requested persistent instructions in AGENTS.md, or an explicitly requested Codex command policy rule; choose the correct format for PI and Codex.
---

# Create persistent guidance

For project conventions or AI guidance, edit the relevant `AGENTS.md`; both PI and Codex load it. Keep root instructions short and move conditional detail into linked project documentation. Read current instructions and nearby conventions, preserve unrelated rules, and proceed when scope is already clear. Put a task-specific skill in `.agents/skills/` only when it adds a distinct triggered workflow.

Command execution policy is a separate Codex feature. If the user explicitly requests it, fetch current [Codex rules documentation](https://learn.chatgpt.com/docs/agent-configuration/rules) using OpenAI Docs when available. `.rules` files contain Starlark `prefix_rule` entries under a `rules/` directory beside an active config layer. Scope the command prefix narrowly, include matching/nonmatching examples, and validate with the current `codex execpolicy check` interface. Do not infer a permission change from a request for prose guidance.

PI does not use Codex `.rules` as enforcement. Requested PI enforcement needs a verified PI extension/event contract, not a renamed policy file. Never write another client's rule format or claim guidance enforces permissions.
