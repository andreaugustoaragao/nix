{ config, pkgs, lib, inputs, ... }:

let
  kanagawa-wallpaper = pkgs.runCommand "kanagawa-wallpaper" {} ''
    mkdir -p $out/share/wallpapers
    cp ${../../assets/wallpapers/kanagawa.jpg} $out/share/wallpapers/kanagawa.jpg
  '';
in
{
  # hyprpaper configuration
  xdg.configFile."hypr/hyprpaper.conf".text = ''
    preload = ${kanagawa-wallpaper}/share/wallpapers/kanagawa.jpg
    wallpaper = ,${kanagawa-wallpaper}/share/wallpapers/kanagawa.jpg
    splash = false
  '';
}