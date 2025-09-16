{ config, pkgs, lib, lockScreen ? false, ... }:

lib.mkIf lockScreen {
  # Lock screen configuration for desktop machines
  home.packages = with pkgs; [
    swaylock-effects
    swayidle
  ];

  # Swaylock configuration with Kanagawa theme
  xdg.configFile."swaylock/config".text = ''
    # Kanagawa-themed lock screen with screenshot background
    screenshots
    clock
    font=CaskaydiaCove Nerd Font
    font-size=14
    
    # Visual effects (screenshot + blur for modern look)
    effect-blur=7x5
    effect-vignette=0.5:0.5
    fade-in=0.2
    
    # Ring colors (Kanagawa palette)
    ring-color=54546d
    key-hl-color=7fb4ca
    line-color=1f1f28
    
    # Inside colors
    inside-color=1f1f2888
    inside-clear-color=7fb4ca88
    inside-ver-color=98bb6c88
    inside-wrong-color=e82424aa
    
    # Text colors
    text-color=dcd7ba
    text-clear-color=1f1f28
    text-ver-color=1f1f28
    text-wrong-color=dcd7ba
    
    # Ring verification/wrong colors
    ring-clear-color=7fb4ca
    ring-ver-color=98bb6c
    ring-wrong-color=e82424
    
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
      {
        timeout = 900; # 15 minutes
        command = "${pkgs.systemd}/bin/systemctl suspend";
      }
    ];
  };


  # Add lock screen keybinding to existing window managers
  # This will be picked up by niri configuration if it imports this
  home.sessionVariables = {
    LOCK_COMMAND = "${pkgs.swaylock-effects}/bin/swaylock -f";
  };
}