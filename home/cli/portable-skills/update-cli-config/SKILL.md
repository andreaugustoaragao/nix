---
name: update-cli-config
description: Change explicitly requested PI or Codex CLI settings while preserving unrelated configuration and this machine's Nix-managed source.
---

# Update CLI configuration

Determine PI versus Codex and the requested setting from context. Inspect the actual file and declarative owner before editing. Do not assume another client's JSON schema or change model/approval/sandbox preferences without an explicit request.

Machine-specific sources:

- Codex runtime: `~/.codex/config.toml`; declarative source: `/home/aragao/projects/personal/nix/home/cli/codex.nix`. The runtime file is materialized by activation and can be overwritten later. Update the source for persistent requested changes; do not expose runtime credential/provider fields in reports.
- PI runtime: `~/.pi/agent/settings.json`; inspect `/home/aragao/projects/personal/nix/home/cli/pi.nix` and actual symlink/activation ownership before choosing the edit location.

For Codex settings, use the system OpenAI Docs skill when available and fetch the current [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference). For PI, inspect the installed `@earendil-works/pi-coding-agent` package's `docs/settings.md` and settings types. Verify the requested key/type against the active version. If a setting is managed policy, report its owner instead of pretending a user override worked.

Patch only requested keys, preserve comments and unrelated values where possible, validate TOML/JSON, and check the relevant client's configuration/discovery behavior. Do not serialize a whole secret-bearing config into task logs. If applying a Nix source change requires activation not authorized by the request, prepare it and state the remaining step.
