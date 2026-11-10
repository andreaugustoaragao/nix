---
name: herdr-coordinate
description: Compatibility alias for chief-of-staff. Use when explicitly asked for herdr-coordinate or Herdr coordination; load the canonical skill and share its ongoing backlog and worker limit.
---

# Herdr coordinate (compatibility alias)

Read and follow the installed chief-of-staff skill at
`~/.agents/skills/chief-of-staff/SKILL.md` (resolve `~` to the user's home before
calling a file tool). Pass the user's request unchanged. In Pi,
`/skill:herdr-coordinate` and in Codex, `$herdr-coordinate` invoke the same
workflow as `chief-of-staff`.

Reuse the current conversation's portfolio if one is active. Do not start a
second coordinator, create a separate queue or multiply worker limits. The
canonical workflow now remains active across tasks until paused or ended;
explain this change when the user invokes the former single-task name.

Keep the old invocation working; recommend `chief-of-staff` for new requests.
Legacy task records remain available for explicit resume as described in the
canonical skill. This alias does not itself launch any workers.
