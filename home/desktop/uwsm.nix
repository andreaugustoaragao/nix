{ config, pkgs, lib, inputs, ... }:

{
  # UWSM desktop entries — NoDisplay so the display manager picks them
  # up but launchers (fuzzel) skip them. No point launching a fresh
  # compositor session from inside the current one.
  xdg.desktopEntries.hyprland-uwsm = {
    name = "Hyprland (UWSM)";
    comment = "Hyprland compositor managed by UWSM";
    exec = "uwsm start hyprland";
    type = "Application";
    noDisplay = true;
  };

  xdg.desktopEntries.niri-uwsm = {
    name = "Niri (UWSM)";
    comment = "Niri compositor managed by UWSM";
    exec = "uwsm start niri";
    type = "Application";
    noDisplay = true;
  };

  # UWSM environment configurations
  xdg.configFile."uwsm/env-hyprland".text = ''
    export XDG_CURRENT_DESKTOP=Hyprland
    export XDG_SESSION_TYPE=wayland
    export XDG_SESSION_DESKTOP=Hyprland
  '';

  xdg.configFile."uwsm/env-niri".text = ''
    export XDG_CURRENT_DESKTOP=niri
    export XDG_SESSION_TYPE=wayland
    export XDG_SESSION_DESKTOP=niri
  '';
}