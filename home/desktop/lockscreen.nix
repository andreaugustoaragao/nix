{
  pkgs,
  lib,
  lockScreen ? false,
  useDms ? false,
  ...
}:

let
  # Same derivation as home/scripts/default.nix installs to
  # ~/.local/bin/screensaver — referenced here by store path so swayidle
  # doesn't depend on the user PATH inside its systemd unit.
  screensaver = import ../scripts/_screensaver.nix { inherit pkgs; };

  # Lock wrapper: cmatrix is a foreground TTY app, so it stays running
  # under swaylock unless killed first. (The screensaver script's EXIT
  # trap nukes it on key-press, but the timeout-driven lock can fire
  # while the screensaver is up.)
  screensaverLock = pkgs.writeShellScript "screensaver-lock" ''
    #!/usr/bin/env bash
    ${pkgs.procps}/bin/pkill -x cmatrix 2>/dev/null || true
    exec ${pkgs.swaylock-effects}/bin/swaylock -f
  '';

  wantLock = lockScreen && !useDms;
in

{
  # swayidle drives the 15-minute screensaver on every desktop host.
  # On hosts with lockScreen=true && !useDms it also drives swaylock at
  # 25 minutes (10 minutes after the screensaver appears) and on
  # before-sleep / lock events. DMS-managed hosts let DMS own the lock
  # screen; servers and Darwin never import this module.
  home.packages = [ pkgs.swayidle ] ++ lib.optionals wantLock [ pkgs.swaylock-effects ];

  # Swaylock configuration with Catppuccin Mocha theme
  xdg.configFile."swaylock/config" = lib.mkIf wantLock {
    text = ''
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
  };

  # Swayidle: screensaver at 15 min. On lockScreen=true && !useDms hosts
  # also locks at 25 min (10-min gap after the screensaver appears) and
  # on before-sleep / lock events.
  services.swayidle = {
    enable = true;
    timeouts = [
      {
        timeout = 900; # 15 minutes
        command = "${screensaver}";
      }
    ]
    ++ lib.optionals wantLock [
      {
        timeout = 1500; # 25 minutes
        command = "${screensaverLock}";
      }
    ];
    events = lib.optionals wantLock [
      {
        event = "before-sleep";
        command = "${pkgs.swaylock-effects}/bin/swaylock -f";
      }
      {
        event = "lock";
        command = "${pkgs.swaylock-effects}/bin/swaylock -f";
      }
    ];
  };

  # Surfaced for window-manager keybindings that want to invoke the lock
  # without hardcoding the swaylock path. Only meaningful where swaylock
  # is the lock implementation.
  home.sessionVariables = lib.mkIf wantLock {
    LOCK_COMMAND = "${pkgs.swaylock-effects}/bin/swaylock -f";
  };
}
