---
name: migrate-to-skills
description: Safely migrate requested legacy commands or conditional guidance into portable PI/Codex skills, verifying discovery and behavior before retiring originals.
---

# Migrate to skills

Inventory source instructions, triggers, scripts, references, and current discovery paths. Classify each as shared project policy, a distinct skill, a client configuration, or obsolete content. Reuse the system Skill Creator when available; do not copy old client APIs or contradictory policies verbatim.

For a portable skill, create a same-named folder containing `SKILL.md` with a nonempty, narrow `name` and `description`. Use `.agents/skills/` for project scope or `~/.agents/skills/` for user scope. Keep only workflow-specific guidance; read conditional references on demand.

Prepare replacements without changing originals. Validate frontmatter and references, inspect actual PI/Codex discovery, and exercise a representative request in a fresh session. Record source-to-destination mapping and any change in behavior. A successful parse does not prove routing or execution.

Once conversion is verified and retirement is in the authorized migration scope, move originals reversibly to a private archive outside every discoverable skill/command directory. Retain digests and a restore procedure that refuses to overwrite later edits. Do not leave archived `SKILL.md` files nested under active roots. Otherwise report that originals remain active and why.

No fixed number of subagents is required. Use independent delegation only when the task or applicable policy requests it and the work benefits from isolation.
