{ pkgs, lib, lockScreen ? false, useDms ? false, ... }:

let
  # Terminal detection mirrors default-terminal.nix.
  # VMs (aarch64) → kitty, desktops → ghostty.
  isVm = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
  termBin = if isVm then "kitty" else "ghostty";

  startScreensaver = pkgs.writeShellScript "start-screensaver" ''
    #!/usr/bin/env bash
    if pgrep -f "^${termBin}" 2>/dev/null | grep -q "cmatrix"; then
      exit 0
    fi
    ${termBin} --class Screensaver -- cmatrix -b -C green
  '';

  triggerLock = pkgs.writeShellScript "trigger-lock" ''
    #!/usr/bin/env bash
    if pgrep -f "cmatrix" >/dev/null 2>&1; then
      killall -TERM cmatrix 2>/dev/null
      sleep 0.2
      pkill -f "cmatrix" 2>/dev/null
    fi
    pkill -x swayidle 2>/dev/null
    rm -f "$HOME/.cache/screensaver-active"
    ${pkgs.swaylock-effects}/bin/swaylock -f
  '';
in

lib.mkIf (lockScreen && !useDms) {
  # Lock screen configuration for desktop machines
  home.packages = with pkgs; [
    swaylock-effects
    swayidle
  ];

  # Swaylock configuration with Catppuccin Mocha theme
  xdg.configFile."swaylock/config".text = ''
    # Catppuccin-themed lock screen with screenshot background
    screenshots
    clock
    font=CaskaydiaCove Nerd Font
    font-size=14

    # Visual effects (screenshot + blur for modern look)
    effect-blur=7x5
    effect-vignette=0.5:0.5
    fade-in=0.2

    # Ring colors (Catppuccin Mocha palette)
    ring-color=585b70
    key-hl-color=89b4fa
    line-color=1e1e2e

    # Inside colors
    inside-color=1e1e2e88
    inside-clear-color=89b4fa88
    inside-ver-color=a6e3a188
    inside-wrong-color=f38ba8aa

    # Text colors
    text-color=cdd6f4
    text-clear-color=1e1e2e
    text-ver-color=1e1e2e
    text-wrong-color=cdd6f4

    # Ring verification/wrong colors
    ring-clear-color=89b4fa
    ring-ver-color=a6e3a1
    ring-wrong-color=f38ba8

    # Separator color
    separator-color=00000000

    # Show failed attempts
    show-failed-attempts

    # Grace period
    grace=2
    grace-no-mouse
    grace-no-touch
  '';

  # Swayidle: screensaver at 5 min, lock at 10 min.
  # The lock command kills the screensaver and stops swayidle before locking.
  services.swayidle = {
    enable = true;
    events = [
      {
        event = "before-sleep";
        command = "${pkgs.swaylock-effects}/bin/swaylock -f";
      }
      {
        event = "lock";
        command = "${pkgs.swaylock-effects}/bin/swaylock -f";
      }
    ];
    timeouts = [
      {
        timeout = 300; # 5 minutes
        command = "${startScreensaver}/bin/start-screensaver";
      }
      {
        timeout = 600; # 10 minutes
        command = "${triggerLock}/bin/trigger-lock";
      }
    ];
  };

  # Add lock screen keybinding to existing window managers
  # This will be picked up by niri configuration if it imports this
  home.sessionVariables = {
    LOCK_COMMAND = "${pkgs.swaylock-effects}/bin/swaylock -f";
  };
}
