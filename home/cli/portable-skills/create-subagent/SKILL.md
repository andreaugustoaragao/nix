---
name: create-subagent
description: Create a requested focused Codex custom agent, or configure an explicitly available PI delegation extension after checking its real contract.
---

# Create a custom agent

Give the agent one responsibility, a specific trigger, file/operation ownership, required inputs, output, and completion check. Inherit model settings unless the user requests a change. Do not mandate review after trivial edits or spawn agents merely because a role exists.

For Codex, fetch current [custom agent documentation](https://learn.chatgpt.com/docs/agent-configuration/subagents) using OpenAI Docs when available. Standalone TOML files belong in `.codex/agents/` or `~/.codex/agents/`. Required strings are `name`, `description`, and `developer_instructions`. Verify other fields against the installed version; parse the TOML and test actual discovery in a new session. Reviewer instructions must require fresh context and read-only behavior; parent runtime overrides can still affect permissions.

For PI, inspect the installed extension's actual delegation tool/schema before configuring it. Core PI does not load Codex agent TOML as custom roles. Agent Hub provides messages/observations and is not itself a builder, review runner, or task scheduler. If no delegation extension exists, use a new PI process with an explicit input brief when authorized; do not invent a native subagent API.

For independent reviews, follow [the review contract](../review/references/independent-review.md). For workers, state ownership and that other agents may be editing the codebase; preserve their edits. Verify a realistic invocation before reporting that a new role works.
