{ config, pkgs, lib, inputs, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.system;
    config.allowUnfree = true;
  };
in
{
  # Hyprland compositor
  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true;
  };

  programs.niri = {
    enable = true;
    package = pkgs-unstable.niri;
  };

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
  services.power-profiles-daemon.enable = true;
  services.fwupd.enable = true;

  services.flatpak.enable = lib.mkForce false;

  # SwayOSD D-Bus policy (required for libinput backend)
  services.dbus.packages = [ pkgs.swayosd ];

  # SwayOSD LibInput backend needs to run as system service for proper D-Bus access
  systemd.services.swayosd-libinput-backend = {
    description = "SwayOSD LibInput backend for input device events";
    wantedBy = [ "multi-user.target" ];
    after = [ "dbus.service" ];
    requires = [ "dbus.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.swayosd}/bin/swayosd-libinput-backend";
      Restart = "on-failure";
      RestartSec = 2;
      User = "root";
      Group = "input";
    };
  };
} 
