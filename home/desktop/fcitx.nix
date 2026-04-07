{ config, pkgs, lib, inputs, ... }:

{
  # Install fcitx5 components
  home.packages = [
    pkgs.fcitx5
    pkgs.fcitx5-gtk
    pkgs.libsForQt5.fcitx5-qt
  ];

  # fcitx5 input method environment
  home.sessionVariables = {
    INPUT_METHOD = "fcitx";
    QT_IM_MODULE = "fcitx";
    XMODIFIERS = "@im=fcitx";
    SDL_IM_MODULE = "fcitx";
  };

  # xcb.conf tweak
  xdg.configFile."fcitx5/conf/xcb.conf".text = ''
    Allow Overriding System XKB Settings=False
  '';
} 