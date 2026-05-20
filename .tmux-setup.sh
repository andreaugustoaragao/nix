#!/usr/bin/env bash
set -euo pipefail

session_name="${1:?tmux session name is required}"
window="${session_name}:1"

# Project layout for this NixOS flake:
#   - top pane: pi-opus (Claude Opus interactive session)
#   - bottom pane: auto-rebuild watcher (sudo, so it prompts for the
#     login password once on startup)
# Focus is left on the watcher pane so the sudo prompt is ready for
# input the moment the session is attached.
tmux rename-window -t "$window" nix

# The pane created by `tmux new-session` becomes the top pane. Use
# send-keys (the shell is already running) instead of replacing it,
# so pi-opus inherits the project's fish environment.
top_pane="$(tmux display-message -p -t "$window" "#{pane_id}")"
tmux send-keys -t "$top_pane" 'pi-opus' Enter

# Bottom pane: run the watcher under sudo so the script itself is
# root (matches the "sudo ./scripts/watch-rebuild.sh" mode documented
# in the script). `exec fish` keeps the pane alive after Ctrl-C so it
# can be restarted without re-laying-out the window.
watcher_pane="$(tmux split-window -v -t "$window" -P -F '#{pane_id}' \
  -c "$PWD" 'sudo ./scripts/watch-rebuild.sh; exec fish')"

tmux select-layout -t "$window" even-vertical
tmux select-pane -t "$watcher_pane"
