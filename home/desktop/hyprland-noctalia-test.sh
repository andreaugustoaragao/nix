if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
  cat <<'USAGE'
Usage: hyprland-noctalia-test

Run from a text console (Ctrl+Alt+F3) after saving your desktop work.
This stops the current graphical session and starts Hyprland with Noctalia.
Logging out of Hyprland restores the default Niri login service.
Restoring the login service may prompt for your sudo password again.
USAGE
  exit 0
fi
if [ "$#" -ne 0 ]; then
  printf '%s\n' 'Usage: hyprland-noctalia-test [--help]' >&2
  exit 2
fi
if [ -n "${WAYLAND_DISPLAY-}" ] || [ -n "${DISPLAY-}" ]; then
  printf '%s\n' 'Run this from a text console (Ctrl+Alt+F3), after saving your desktop work.' >&2
  exit 1
fi
test_tty=$(tty) || {
  printf '%s\n' 'A local text console is required.' >&2
  exit 1
}
case "$test_tty" in
  /dev/tty[0-9]*) ;;
  *)
    printf '%s\n' 'A local text console is required; terminal windows and SSH are not supported.' >&2
    exit 1
    ;;
esac

restore_greetd=false
if systemctl is-active --quiet greetd.service; then
  sudo -v
  restore_greetd=true
fi
restore_default_session() {
  session_status=$?
  trap - EXIT INT TERM
  systemctl --user stop graphical-session.target || true
  if "$restore_greetd"; then
    if ! sudo systemctl start greetd.service; then
      printf '%s\n' 'To restore Niri, run: sudo systemctl start greetd.service' >&2
      return 1
    fi
  fi
  return "$session_status"
}
trap restore_default_session EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if "$restore_greetd"; then
  sudo systemctl stop greetd.service
fi
systemctl --user stop graphical-session.target
systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY NIRI_SOCKET HYPRLAND_INSTANCE_SIGNATURE
unset WAYLAND_DISPLAY DISPLAY NIRI_SOCKET HYPRLAND_INSTANCE_SIGNATURE

uwsm start -e -D Hyprland:NoctaliaTest "$hyprland_noctalia_compositor" -- --config "$hyprland_noctalia_config"
