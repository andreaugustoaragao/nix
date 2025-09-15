{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ./hyprland.nix
    ./niri.nix
    ./wayland-services.nix
    ./wofi.nix
    ./wlogout.nix
    ./mako.nix
    ./gtk.nix
    ./qt.nix
    ./ghostty.nix
    ./foot.nix
    ./alacritty.nix
    ./swayosd.nix
    ./hyprpaper.nix
    ./uwsm.nix
    ./screenshot.nix
    ./brave.nix
    ./firefox.nix
    ./qutebrowser.nix
    ./vscode.nix
    ./waybar.nix
    ./wallpapers.nix
    ./fcitx.nix
    ./thunar.nix
    ./xresources.nix
    ./cursors.nix
    ./mimeapps.nix
    ./notes.nix
    ./web-apps-launcher.nix
  ];

  home.packages = with pkgs; [
    pavucontrol
    xdg-desktop-portal-gnome
    xdg-desktop-portal-gtk
    teams-for-linux
    bitwarden
    neovide
    swayimg
    obsidian
  ];
}