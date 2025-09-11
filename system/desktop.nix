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

  # Enable Flatpak and auto-install Flathub + Zen Browser (system-wide)
  services.flatpak.enable = true;
  system.activationScripts.flatpakFlathubZen.text = ''
    ${pkgs.flatpak}/bin/flatpak --system remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    ${pkgs.flatpak}/bin/flatpak --system install -y flathub app.zen_browser.zen || true
  '';
} 
