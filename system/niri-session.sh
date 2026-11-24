set -e

# Refuse to start a second niri-session while a live niri compositor already
# owns this runtime directory / user bus: running niri-shutdown.target or
# niri --session would tear down graphical-session.target and steal Mutter
# D-Bus names (breaking ScreenCast) from the active desktop.
check_live_niri_socket() {
  local sock=$1
  [ -n "$sock" ] && [ -S "$sock" ] && NIRI_SOCKET="$sock" "$NIRI_BIN" msg version >/dev/null 2>&1
}

if check_live_niri_socket "${NIRI_SOCKET:-}"; then
  printf 'niri-session: refusing to start while %s is active (use an isolated XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS for a separate session)\n' "$NIRI_SOCKET" >&2
  exit 1
fi

if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  for sock in "$XDG_RUNTIME_DIR"/niri.*.sock; do
    if check_live_niri_socket "$sock"; then
      printf 'niri-session: refusing to start while %s is active (use an isolated XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS for a separate session)\n' "$sock" >&2
      exit 1
    fi
  done
fi

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
