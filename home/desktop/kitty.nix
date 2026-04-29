{
  config,
  pkgs,
  lib,
  inputs,
  useDms ? false,
  ...
}:

{
  programs.kitty = {
    enable = true;
    # When DMS owns the desktop, layer matugen-generated colors on top
    # of the static Kanagawa fallback below (later `include` wins).
    extraConfig = lib.optionalString useDms ''
      include dank-theme.conf
      include dank-tabs.conf
    '';
    font = {
      name = "CaskaydiaMono Nerd Font";
      size = 9;
    };
    settings = {
      shell = "fish";
      window_padding_width = 5;
      background_opacity = "0.98";
      confirm_os_window_close = 0;
      wayland_enable_ime = "no";
      update_check_interval = 0;

      # Kanagawa colors
      foreground = "#dcd7ba";
      background = "#1f1f28";

      # Black
      color0 = "#090618";
      color8 = "#727169";

      # Red
      color1 = "#c34043";
      color9 = "#e82424";

      # Green
      color2 = "#76946a";
      color10 = "#98bb6c";

      # Yellow
      color3 = "#c0a36e";
      color11 = "#e6c384";

      # Blue
      color4 = "#7e9cd8";
      color12 = "#7fb4ca";

      # Magenta
      color5 = "#957fb8";
      color13 = "#938aa9";

      # Cyan
      color6 = "#6a9589";
      color14 = "#7aa89f";

      # White
      color7 = "#c8c093";
      color15 = "#dcd7ba";
    };
  };
}
