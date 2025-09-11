{ config, pkgs, lib, inputs, ... }:

{
  # Ensure mako is installed
  home.packages = [ pkgs.mako ];

  # Mako notification daemon configuration (Wayland) - manual config file
  xdg.configFile."mako/config".text = ''
    # Kanagawa theme colors
    background-color=#1f1f28e6
    text-color=#dcd7ba
    border-color=#54546d
    
    # Layout and positioning
    anchor=top-right
    width=400
    height=110
    margin=10
    padding=15
    border-size=2
    border-radius=8
    
    # Basic settings
    default-timeout=10000
  '';
}