{ config, pkgs, lib, inputs, ... }:

let
  kanagawa-wallpaper = pkgs.runCommand "kanagawa-wallpaper" {} ''
    mkdir -p $out/share/wallpapers
    cp ${../../assets/wallpapers/kanagawa.jpg} $out/share/wallpapers/kanagawa.jpg
  '';
in
{
  # Add wallpaper package to user environment
  home.packages = [ kanagawa-wallpaper ];
  
  # Make wallpaper path available as environment variable
  home.sessionVariables = {
    KANAGAWA_WALLPAPER = "${kanagawa-wallpaper}/share/wallpapers/kanagawa.jpg";
  };
} 