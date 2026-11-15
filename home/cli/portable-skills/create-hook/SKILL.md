---
name: create-hook
description: Create or update a requested Codex lifecycle hook or PI event extension, using the actual client schema and a verified event contract.
---

# Create a hook

Identify the client and requested event/outcome from the task. Codex and PI have different extension systems.

For Codex, use current [official hooks documentation](https://learn.chatgpt.com/docs/hooks) through the system OpenAI Docs skill when available. Hooks live beside active config layers in `hooks.json` or `[hooks]` in `config.toml`; prefer one representation per layer. Inspect existing hooks and the actual CLI version before editing. Validate the requested event's input, output, timeout, and error behavior; do not copy another client's event catalog.

For PI, inspect the installed `@earendil-works/pi-coding-agent` package's `docs/extensions.md`, event examples, and types. An extension exports a factory receiving `ExtensionAPI` and registers `pi.on(...)`. Use `.pi/extensions/` for the project or `~/.pi/agent/extensions/` for the user. Do not call Codex hooks PI hooks.

Keep the handler small and preserve unrelated configuration. Nix-managed files must be changed in their declarative source; declare system tooling there rather than using global installers. Test the handler with realistic success, failure, and malformed-input fixtures. Then verify discovery and the event in the actual client. Loading a script is not proof that an event fired or blocked an operation.

Codex non-managed hooks require the client's review/trust step. Report pending trust accurately; do not change the launcher or bypass trust as part of creating a hook. PI extensions run with the PI process's permissions, so record their file/tool access in the implementation.
