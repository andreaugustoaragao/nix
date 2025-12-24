{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ./hyprland.nix
    ./niri.nix
    ./wayland-services.nix
    ./wofi.nix
    ./wlogout.nix
    ./lockscreen.nix
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
    ./eww.nix
    ./wallpapers.nix
    ./fcitx.nix
    ./thunar.nix
    ./xresources.nix
    ./cursors.nix
    ./mimeapps.nix
    ./notes.nix
    ./window-switcher.nix
    ./web-apps-launcher.nix
    ./do-not-disturb.nix
    ./quickshell.nix
  ];

  home.packages = with pkgs; [
    pavucontrol
    xdg-desktop-portal-gnome
    xdg-desktop-portal-gtk
    teams-for-linux
    telegram-desktop
    bitwarden-desktop
    neovide
    swayimg
    obsidian
    qt6.qttools
    
    # Video-related packages
    mpv
    obs-studio
    obs-studio-plugins.advanced-scene-switcher
    kdePackages.kdenlive
  ] ++ lib.optionals (pkgs.stdenv.system == "x86_64-linux") [
    zoom-us
  ];
}