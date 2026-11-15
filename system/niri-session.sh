set -e

# A previous launcher may have left the desktop target active after logout.
"$SYSTEMCTL_BIN" --user start --job-mode=replace-irreversibly niri-shutdown.target

export XDG_CURRENT_DESKTOP=niri
export XDG_SESSION_DESKTOP=niri
export XDG_SESSION_TYPE=wayland

compositor_pid=
cleanup() {
  trap - EXIT HUP INT TERM
  if [ -n "$compositor_pid" ] && kill -0 "$compositor_pid" 2>/dev/null; then
    kill -TERM "$compositor_pid"
    wait "$compositor_pid" || true
  fi
  "$SYSTEMCTL_BIN" --user start --job-mode=replace-irreversibly niri-shutdown.target
  "$SYSTEMCTL_BIN" --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP NIRI_SOCKET HYPRLAND_INSTANCE_SIGNATURE
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Keep the compositor and its auth agent in greetd's logind session scope.
"$NIRI_BIN" --session &
compositor_pid=$!
wait "$compositor_pid"
