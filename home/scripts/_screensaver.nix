{ pkgs, inputs, ... }:

let
  ttfx = pkgs.callPackage ../../pkgs/ttfx.nix { src = inputs.ttfx-src; };
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
    pkgs.figlet
    pkgs.inetutils
    ttfx
    pkgs.util-linux
    terminal
  ];
  effect = pkgs.writeShellScript "screensaver-effect" ''
    export PATH="${binPath}:''${PATH:-}"
    text=$(mktemp)
    effect_pid=""
    cleanup() {
      if [ -n "$effect_pid" ]; then
        kill "$effect_pid" 2>/dev/null || true
        wait "$effect_pid" 2>/dev/null || true
      fi
      rm -f "$text"
      printf '\033[?25h\033[?1003l\033[?1006l'
    }
    trap cleanup EXIT
    trap 'exit 0' TERM INT HUP

    # Wait for the compositor to resize the newly opened terminal.
    deadline=$((SECONDS + 2))
    while (( SECONDS < deadline )) && [ "$(stty size)" = "24 80" ]; do
      sleep 0.02
    done
    read -r _ columns < <(stty size)
    figlet -f small -w "$columns" "$(hostname -s)" > "$text"
    printf '\033]11;rgb:00/00/00\007\033[2J\033[H\033[?25l\033[?1003h\033[?1006h'

    while true; do
      ttfx -i "$text" --frame-rate 120 --canvas-width 0 --canvas-height 0 \
        --reuse-canvas --anchor-canvas c --anchor-text c \
        --random-effect --no-eol --no-restore-cursor &
      effect_pid=$!
      while kill -0 "$effect_pid" 2>/dev/null; do
        # Mouse reporting turns movement into input, just like a key press.
        if IFS= read -r -s -n 1 -t 0.1; then
          exit 0
        fi
      done
      wait "$effect_pid" || true
      effect_pid=""
    done
  '';

in

# Omarchy-style animated hostname on every connected output. Any keyboard
# or mouse input closes the focused terminal and the launcher sweeps the rest.
pkgs.writeShellScript "screensaver" ''
  #!/usr/bin/env bash
  set -u

  # swayidle hands us a bash-only PATH; prepend our pinned tools and the
  # system profile (for the running niri/hyprctl) so bare-name calls resolve.
  export PATH="${binPath}:/run/current-system/sw/bin:''${PATH:-}"

  pids=()
  lockdir="''${XDG_RUNTIME_DIR:-/tmp}/screensaver.lock"
  if ! mkdir "$lockdir" 2>/dev/null; then
    exit 0
  fi
  cleanup() {
    for pid in "''${pids[@]}"; do
      kill -- "-$pid" 2>/dev/null || true
    done
    rm -rf "$lockdir"
  }
  trap cleanup EXIT
  trap 'exit 0' TERM INT

  outputs=()
  focus_output() { :; }
  screensaver_count() { echo 0; }

  if [ -n "''${NIRI_SOCKET:-}" ]; then
    mapfile -t outputs < <(
      niri msg --json outputs |
        ${pkgs.jq}/bin/jq -r 'to_entries[] | select(.value.current_mode != null) | .key'
    )
    focus_output() { niri msg action focus-monitor "$1" >/dev/null 2>&1 || true; }
    screensaver_count() {
      niri msg --json windows | ${pkgs.jq}/bin/jq '[.[] | select(.app_id == "Screensaver")] | length'
    }
  elif [ -n "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    mapfile -t outputs < <(
      hyprctl -j monitors | ${pkgs.jq}/bin/jq -r '.[].name'
    )
    focus_output() { hyprctl dispatch focusmonitor "$1" >/dev/null 2>&1 || true; }
    screensaver_count() {
      hyprctl -j clients | ${pkgs.jq}/bin/jq '[.[] | select(.class == "Screensaver" and .mapped)] | length'
    }
  fi

  # Compositor unknown / no outputs found — fall back to one window
  # on whatever monitor is currently focused.
  if [ ''${#outputs[@]} -eq 0 ]; then
    outputs=(__current__)
  fi

  for out in "''${outputs[@]}"; do
    before=$(screensaver_count)
    if [ "$out" != "__current__" ]; then
      focus_output "$out"
      sleep 0.1
    fi
    ${pkgs.util-linux}/bin/setsid ${termBin} --class Screensaver ${
      if isVm then
        "--override background_opacity=1 --override window_padding_width=0"
      else
        "--background-opacity=1 --window-padding-x=0 --window-padding-y=0 -e"
    } ${effect} &
    pids+=("$!")
    # Terminal creation is asynchronous. Keep focus on this output until
    # its window maps; a fixed delay lets slow windows land on the next one.
    if [ "$out" != "__current__" ]; then
      deadline=$((SECONDS + 10))
      while [ "$(screensaver_count)" -le "$before" ]; do
        if (( SECONDS >= deadline )); then
          echo "Screensaver terminal did not appear on $out within 10 seconds" >&2
          exit 1
        fi
        sleep 0.05
      done
    fi
  done

  # Closing one terminal dismisses all screensaver instances.
  wait -n "''${pids[@]}" 2>/dev/null || true
''
