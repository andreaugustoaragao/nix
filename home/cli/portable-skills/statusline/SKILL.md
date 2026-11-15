---
name: statusline
description: Configure a requested Codex footer status line or PI footer customization using the actual client format and inexpensive rendering.
---

# Configure the footer

For Codex, prefer the built-in `/statusline` picker when the user is operating the CLI. For a requested file edit, fetch current [CLI customization](https://learn.chatgpt.com/docs/cli-customization) and [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference) through OpenAI Docs when available. Codex uses `tui.status_line` in its active `config.toml`, not a script payload in another client's JSON settings.

A current documented example is:

```toml
[tui]
status_line = ["model", "context-remaining", "git-branch"]
```

Verify accepted item identifiers in the installed version before editing. Preserve unrelated `[tui]` keys. On this machine the user Codex config is materialized by Nix; update its declarative source for lasting changes.

For PI, use its real extension/footer API. Inspect the installed package's `docs/extensions.md`, `docs/tui.md`, and footer example/types before writing an extension. Keep rendering cheap: cached state or event-driven updates, no repeated expensive per-prompt subprocesses. Verify actual display in a PI session; loading an extension alone does not prove its footer works.

Do not change models, permissions, or unrelated preferences while customizing the footer. Record any required reload/restart accurately.
