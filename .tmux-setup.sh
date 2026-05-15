#!/usr/bin/env bash
set -euo pipefail

session_name="${1:?tmux session name is required}"
window="${session_name}:1"

# Project layout for this NixOS flake:
#   - two regular shells for editing/commands
#   - bottom pane runs the auto-rebuild watcher
tmux rename-window -t "$window" nix
top_pane="$(tmux display-message -p -t "$window" "#{pane_id}")"

tmux split-window -v -t "$window" -c "$PWD"
tmux split-window -v -t "$window" -c "$PWD" './scripts/watch-rebuild.sh; exec fish'
tmux select-layout -t "$window" even-vertical
tmux select-pane -t "$top_pane"
