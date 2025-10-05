{ config, pkgs, lib, inputs, ... }:

{
  # Install QuickShell for the user, not system-wide
  home.packages = [
    (if pkgs ? quickshell then pkgs.quickshell else inputs.nixpkgs-unstable.legacyPackages.${pkgs.system}.quickshell)
    pkgs.socat
    pkgs.pamixer
    pkgs.wireplumber
    pkgs.lm_sensors
  ];

  # QuickShell configuration files
  # Temporarily commented out to work directly in ~/.config/quickshell/
  #    xdg.configFile = {
  #    "quickshell/Config.qml".source = ./quickshell/Config.qml;
  #    "quickshell/shell.qml".source = ./quickshell/shell.qml;
  #    "quickshell/NiriService.qml".source = ./quickshell/NiriService.qml;
  #    "quickshell/CompositorService.qml".source = ./quickshell/CompositorService.qml;
  #    "quickshell/AudioService.qml".source = ./quickshell/AudioService.qml;
  #  };
} 