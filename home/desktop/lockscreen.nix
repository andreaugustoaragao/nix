{
  pkgs,
  lib,
  lockScreen ? false,
  useDms ? false,
  ...
}:

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

  # Swayidle configuration for auto-locking
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
        timeout = 600; # 10 minutes
        command = "${pkgs.swaylock-effects}/bin/swaylock -f";
      }
      # {
      #   timeout = 900; # 15 minutes
      #   command = "${pkgs.systemd}/bin/systemctl suspend";
      # }
    ];
  };

  # Add lock screen keybinding to existing window managers
  # This will be picked up by niri configuration if it imports this
  home.sessionVariables = {
    LOCK_COMMAND = "${pkgs.swaylock-effects}/bin/swaylock -f";
  };
}
