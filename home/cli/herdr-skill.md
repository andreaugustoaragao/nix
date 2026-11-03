---
name: herdr
description: Control Herdr TUI or Herdr Desktop when requested, or identify which Herdr hosts the current terminal. Desktop uses HC_TERMINAL_ID; the legacy TUI uses HERDR_ENV=1.
---

# Herdr

Run `agent-host-context` through the current shell tool before choosing a CLI.

- For `HC_TERMINAL_ID`, load the `herdr-core` skill and run `hc --skill`.
  For Desktop window operations, also run `herdr-app --skill`.
- For `HERDR_ENV=1` with `HERDR_PANE_ID` and `HERDR_SOCKET_PATH`, read
  [the pinned TUI manual](references/tui.md), then use `herdr`.
- If both contexts are present, identify the intended target. They are separate
  runtimes with different IDs and commands.
- If neither context is present, report the missing markers rather than
  controlling a focused or default session.

The absence of `HERDR_ENV` does not rule out Herdr Desktop. `TERM_PROGRAM` and a
shared agent server's launch environment do not identify the current terminal.
