{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [ eww ];

  home.shellAliases = {
    eww-bar = "eww daemon >/dev/null 2>&1 & sleep 0.2 && eww open bar";
    eww-bar-close = "eww close bar || true";
    eww-reload = "eww reload";
  };

  xdg.desktopEntries.eww-bar = {
    name = "Eww Bar";
    comment = "Launch the Eww status bar";
    exec = ''sh -c "eww daemon >/dev/null 2>&1 & sleep 0.2 && eww open bar"'';
    terminal = false;
    categories = [ "Utility" ];
  };
} 