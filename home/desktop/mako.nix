{
  pkgs,
  lib,
  useDms ? false,
  ...
}:

{
  # mako is the notification daemon when DMS isn't running. Under DMS,
  # DMS itself owns org.freedesktop.Notifications natively, so don't
  # install mako at all — having the binary on PATH is what lets stale
  # processes accidentally race DMS for the dbus slot.
  home.packages = lib.optionals (!useDms) [ pkgs.mako ];

  xdg.configFile."mako/config" = lib.mkIf (!useDms) {
    text = ''
      # Catppuccin Mocha theme colors
      background-color=#1e1e2ee6
      text-color=#cdd6f4
      border-color=#585b70

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
