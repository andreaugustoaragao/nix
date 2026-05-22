{ pkgs, lib, ... }:

let
  # Auto-detect terminal for screensaver — mirrors default-terminal.nix.
  # aarch64 (VMs) → kitty, x86_64 (desktops) → ghostty.
  isVm = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
  termBin = if isVm then "kitty" else "ghostty";

  screensaver = pkgs.writeShellScript "screensaver" ''
    #!/usr/bin/env bash
    if pgrep -f "^${termBin}" 2>/dev/null | grep -q "cmatrix"; then
      exit 0
    fi
    ${termBin} --class Screensaver -- cmatrix -b -C green
  '';

  lockscreen = pkgs.writeShellScript "lockscreen" ''
    #!/usr/bin/env bash
    if pgrep -f "cmatrix" >/dev/null 2>&1; then
      killall -TERM cmatrix 2>/dev/null
      sleep 0.2
      pkill -f "cmatrix" 2>/dev/null
    fi
    pkill -x swayidle 2>/dev/null
    rm -f "$HOME/.cache/screensaver-active"
    swaylock -f
  '';
in
{
  imports = [
    ./bw-query.nix
    ./bookmarks.nix
    ./browser-app.nix
    ./browser-default.nix
    ./eww.nix
    ./fulcrum-logs.nix
    ./record-call.nix
  ];

  # Screensaver — terminal-based cmatrix display.
  # On non-DMS hosts (hp-laptop) this is wired into swayidle timeouts.
  # On DMS hosts (workstation) it's available as a manual keybinding.
  home.file.".local/bin/screensaver" = {
    source = screensaver;
    executable = true;
  };
  home.file.".local/bin/lockscreen" = {
    source = lockscreen;
    executable = true;
  };
}
