{ pkgs, ... }:

let
  # Shared with home/desktop/lockscreen.nix so the swayidle timeout and
  # the Mod+Ctrl+S keybinding both resolve to the same store path.
  screensaver = import ./_screensaver.nix { inherit pkgs; };

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

  # Wrap the bare writeShellScript derivations into $out/bin/ packages
  # so they land on ~/.nix-profile/bin/ — niri's spawn PATH includes
  # the home-manager profile but NOT ~/.local/bin, so a keybind like
  # `spawn "screensaver"` only resolves when the script is on a
  # profile bin path.
  screensaverBin = pkgs.runCommand "screensaver-bin" { } ''
    mkdir -p $out/bin
    ln -s ${screensaver} $out/bin/screensaver
  '';
  lockscreenBin = pkgs.runCommand "lockscreen-bin" { } ''
    mkdir -p $out/bin
    ln -s ${lockscreen} $out/bin/lockscreen
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
  home.packages = [
    screensaverBin
    lockscreenBin
  ];
}
