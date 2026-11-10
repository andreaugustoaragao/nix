# Rebuild Log Rune

A read-only, native Rune viewer for NixOS rebuild output. No terminal, webview,
Zenity dialogs, or build/authentication actions. Closing the viewer cannot stop
a rebuild.

```sh
nix run .#rebuild-log-rune -- \
  --log "$HOME/.local/state/noctalia-nix-rebuild/rebuild.log" \
  --status "$HOME/.local/state/noctalia-nix-rebuild/status.json"
```

`--status` is optional. Without `--log`, the viewer reads the usual log under
`$XDG_STATE_HOME/noctalia-nix-rebuild` (or `~/.local/state`). Rune's standard
`--snap`, `--size`, `--theme`, `--tree`, and scripted-input options are also
available.

## Controls

- **Following / Follow** pauses or resumes live following. Scrolling into
  history pauses it automatically; **End** returns to the latest output.
- **Ctrl+F** focuses search. **Enter / Shift+Enter** navigate matching lines.
  **Escape** clears a focused search and restores the full text filter.
- **Filter matches** hides nonmatching lines. **All / Issues / Errors** filter
  by inferred severity. Warning/error message prefixes are a heuristic, not a
  structured Nix event type.
- **Timestamps** show the local capture date/time beside new messages (for
  example `09 Nov 17:08:09`). Hover for the full year and UTC offset. Capture
  times are saved in the log, so reopening does not change them. Older lines
  without timestamps stay unknown rather than using file modification times.
- **Copy** copies selected text, or every filtered line if no text is selected.
  Offscreen filtered lines and their full capture timestamps are included. Normal mouse selection and Ctrl+C
  also work. Virtualized text selection covers mounted rows; Copy with no
  selection is the way to capture the full filtered history.
- **Wrap** switches between wrapped lines and horizontal scrolling.
- **Ctrl+W** or the window close button closes the viewer only.

The palette follows the desktop's dark/light preference. ANSI control
sequences are removed before display, and warnings/errors are colored by the
viewer. File I/O and parsing run on a background worker; a coalescing inbox
prevents a backlog of snapshots. Quiet polling does not redraw the UI. Rune
virtual rows keep layout bounded to the viewport.

History is capped at the last **16 MiB / 100,000 lines** to keep memory bounded.
When capped, a notice is displayed and line numbers are relative to the
retained tail. File replacement and truncation (a new rebuild) are detected.
This is an lnav-inspired rebuild viewer, not an implementation of lnav's SQL
engine or log-format catalog.

## Development

```sh
nix develop .#rebuild-log-rune --command cargo test \
  --manifest-path home/desktop/rebuild-log-rune/Cargo.toml
nix build .#rebuild-log-rune
```

The Cargo manifest pins the same Rune revision as the existing Yazi Rune app.
Cascadia Code is embedded for reproducible monospace output, under the included
SIL Open Font License in `assets/Cascadia-LICENSE.txt`.
The Nix package runs parser, state, virtualization, and native control tests.
