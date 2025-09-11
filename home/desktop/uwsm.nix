{ config, pkgs, lib, inputs, ... }:

{
  # UWSM configuration for Hyprland
  xdg.desktopEntries.default = {
    name = "Hyprland";
    comment = "Hyprland compositor";
    exec = "Hyprland";
    type = "Application";
  };

  # UWSM Hyprland service
  xdg.configFile."uwsm/env".text = ''
    export XDG_CURRENT_DESKTOP=niri
    export XDG_SESSION_TYPE=wayland
    export XDG_SESSION_DESKTOP=niri
  '';
}