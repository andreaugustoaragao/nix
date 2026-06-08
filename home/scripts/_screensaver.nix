{ pkgs, ... }:

let
  # Mirrors default-terminal.nix selection. Kept private to this file —
  # consumers should reference the resulting derivation, not termBin.
  isVm = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
  terminal = if isVm then pkgs.kitty else pkgs.ghostty;
  termBin = if isVm then "kitty" else "ghostty";

  # swayidle invokes this with PATH set to just bash — the home-manager
  # `services.swayidle` module hardcodes `Environment=PATH=<bash>/bin`, so
  # without an explicit PATH the script dies at its very first `mkdir`
  # (coreutils isn't reachable) and the screensaver never appears. Pin the
  # must-have tools by store path; the compositor IPC (niri/hyprctl) comes
  # from the system profile so it tracks the running compositor's version
  # rather than a possibly-skewed pkgs pin.
  binPath = pkgs.lib.makeBinPath [
    pkgs.coreutils
    pkgs.cmatrix
    terminal
  ];
in

# Fullscreen cmatrix on every connected output. cmatrix -s (screensaver
# mode) exits on the first keystroke on whatever terminal has focus;
# the EXIT trap then sweeps the rest. Compositor-specific bits use
# niri/hyprctl IPC to enumerate outputs and shift focus before each
# spawn — the WM rule `class:Screensaver → fullscreen` (defined in
# home/desktop/niri.nix and home/desktop/hyprland.nix) lands each new
# window on the freshly-focused monitor.
pkgs.writeShellScript "screensaver" ''
  #!/usr/bin/env bash
  set -u

  # swayidle hands us a bash-only PATH; prepend our pinned tools and the
  # system profile (for the running niri/hyprctl) so bare-name calls resolve.
  export PATH="${binPath}:/run/current-system/sw/bin:''${PATH:-}"

  lockdir="''${XDG_RUNTIME_DIR:-/tmp}/screensaver.lock"
  if ! mkdir "$lockdir" 2>/dev/null; then
    exit 0
  fi
  cleanup() {
    ${pkgs.procps}/bin/pkill -x cmatrix 2>/dev/null || true
    rm -rf "$lockdir"
  }
  trap cleanup EXIT TERM INT

  outputs=()
  focus_output() { :; }

  if [ -n "''${NIRI_SOCKET:-}" ]; then
    mapfile -t outputs < <(
      niri msg --json outputs |
        ${pkgs.jq}/bin/jq -r 'to_entries[] | select(.value.current_mode != null) | .key'
    )
    focus_output() { niri msg action focus-monitor "$1" >/dev/null 2>&1 || true; }
  elif [ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    mapfile -t outputs < <(
      hyprctl -j monitors | ${pkgs.jq}/bin/jq -r '.[].name'
    )
    focus_output() { hyprctl dispatch focusmonitor "$1" >/dev/null 2>&1 || true; }
  fi

  # Compositor unknown / no outputs found — fall back to one window
  # on whatever monitor is currently focused.
  if [ ''${#outputs[@]} -eq 0 ]; then
    outputs=(__current__)
  fi

  pids=()
  for out in "''${outputs[@]}"; do
    if [ "$out" != "__current__" ]; then
      focus_output "$out"
      sleep 0.1
    fi
    ${termBin} --class Screensaver -- cmatrix -bs -C green &
    pids+=("$!")
    sleep 0.15
  done

  # Wait for the first cmatrix terminal to exit (cmatrix -s exits on
  # any keystroke). The EXIT trap kills the remaining instances.
  wait -n "''${pids[@]}" 2>/dev/null || true
''
