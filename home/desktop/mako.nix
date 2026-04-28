{
  config,
  pkgs,
  lib,
  inputs,
  useDms ? false,
  ...
}:

{
  # Ensure mako is installed
  home.packages = [ pkgs.mako ];

  # mako has no `include` directive — when DMS is on, matugen writes
  # the entire ~/.config/mako/config, so skip writing it from Nix.
  xdg.configFile."mako/config" = lib.mkIf (!useDms) {
    text = ''
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

      [mode=do-not-disturb]
      invisible=1
    '';
  };
}
