{ config, pkgs, lib, inputs, ... }:

{
  # Hyprland compositor
  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true;
  };

  programs.niri.enable = true;

  environment.systemPackages = with pkgs; [ xwayland-satellite ];
  environment.sessionVariables = { WLR_NO_HARDWARE_CURSORS = "0"; };

#  xdg.portal = {
#    enable = true;
#    extraPortals = with pkgs; [
#      xdg-desktop-portal-gnome
#      xdg-desktop-portal-hyprland
#      xdg-desktop-portal-gtk
#      xdg-desktop-portal-gnome
#    ];
#    config.common = {
#      default = [ "gtk" ];
#    };
#config.niri = {
#      default = [ "gnome" "gtk"  ];
#    };
#  };

  programs.dconf.enable = true;

  services.upower.enable = true;
} 
