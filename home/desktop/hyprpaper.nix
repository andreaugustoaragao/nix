{ config, pkgs, lib, inputs, ... }:

{
  # hyprpaper configuration
  xdg.configFile."hypr/hyprpaper.conf".text = ''
    preload = ${config.home.homeDirectory}/.local/share/wallpapers/1-kanagawa.jpg
    wallpaper = ,${config.home.homeDirectory}/.local/share/wallpapers/1-kanagawa.jpg
    splash = false
  '';
}