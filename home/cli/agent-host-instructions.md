# Terminal host

When identifying or controlling the terminal host, run `agent-host-context`
through your current shell tool. It reports selected environment variables and
command paths without contacting a server. Check this before concluding that
Herdr or Orca is unavailable. An installed command alone does not identify the
current terminal.

- `HC_TERMINAL_ID` identifies a herdr-core terminal, including Herdr Desktop.
  `HC_TERMINAL_SOCKET` identifies its owning core. Use the `herdr-core` skill,
  `hc --skill`, and `herdr-app --skill` for Desktop window operations.
- `HERDR_ENV=1`, with `HERDR_PANE_ID` and `HERDR_SOCKET_PATH`, identifies the
  legacy Herdr TUI context. Use the `herdr` skill and its TUI reference.
- `ORCA_PANE_KEY` identifies an Orca-managed terminal. Structured sessions use
  `ORCA_STRUCTURED_SESSION=1` and `ORCA_AGENT_SESSION_ID` instead. Use the `orca`
  skill to choose the CLI and load its version-matched guide. `ORCA_ENVIRONMENT`
  selects a remote runtime; it does not prove this terminal is inside Orca.

`TERM_PROGRAM` alone is not a reliable host detector. Core can report `ghostty`.
Read the current tool subprocess environment, not a shared agent server's
startup environment. Keep partial or overlapping markers visible; if more than
one host is present, identify the intended target before issuing control
commands. A core terminal marker does not prove a Desktop window is attached.

Use the CLI belonging to the target host and explicit terminal or pane IDs.
Load host skills when host interaction is needed; their availability alone does
not require delegation. Nix manages these packages and integrations, so make
persistent changes in the Nix source. Orca owns its separate runtime hooks and
managed agent homes; let its native setup maintain those files alongside the
Nix-managed hooks. The Nix Codex launcher uses `--no-daemon` in managed terminals
so tool commands and hooks inherit the calling terminal's context.

When creating or arranging Herdr Desktop / core items (`herdr-app`, `hc`), name
them explicitly instead of leaving numbered defaults or unnamed sessions:

- **Chief-of-staff topology:** each space may have at most one
  `chief-of-staff`, in a tab named `chief-of-staff` (`herdr.role=chief-of-staff`).
  All child agents of that coordinator must open on separate worker tabs in the
  same space, with up to 4 splits per tab (never inside `chief-of-staff`).
- **Spaces (`space.new` / `space.rename`):** `<repo>` for main checkouts, or
  `<repo> · <worktree-or-branch>` for linked worktrees; disambiguate if another
  space already uses `<repo>`.
- **Tabs (`tab.new` / `tab.rename`):** `chief-of-staff` for the coordinator tab;
  concise topic/task name for other tabs (e.g. `Auth review`,
  `T020 · Fast startup`), never generic `"1"` or bare agent names.
- **Splits & `hc` terminals (`hc run --name`, `hc label`):** kebab-case
  `<topic-or-task>-<role>` (e.g. `t020-impl`, `auth-review`, `nix-check`). When
  creating or adopting a Desktop split (`pane.split`, `terminal.open`,
  `terminal.keep`), label it with `hc label <t> herdr.name=<role-or-topic>` if it
  was not launched with `--name`. Never overwrite user-named spaces or tabs.

UX-level development whose iteration or verification restarts a Wayland
compositor or session must run in its own Wayland session. Do not restart,
replace, or switch the session the user is working in. Build and inspect the
change in the separate session, then leave the user's session running.
