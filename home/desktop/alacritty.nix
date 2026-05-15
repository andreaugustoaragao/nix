{
  config,
  pkgs,
  lib,
  inputs,
  useDms ? false,
  ...
}:

{
  programs.alacritty = {
    enable = true;
    settings = {
      # Alacritty merges imports under the local config — i.e. local
      # keys win over imports. So under DMS we drop the static Kanagawa
      # `colors` block entirely; the imported dank-theme.toml owns the
      # palette. The non-DMS path keeps Kanagawa as a static fallback.
      general.import = lib.optionals useDms [ "~/.config/alacritty/dank-theme.toml" ];

      window = {
        opacity = 0.98;
        decorations = "none";
        padding = {
          x = 14;
          y = 14;
        };
      };

      font = {
        normal = {
          family = "CaskaydiaMono Nerd Font";
          style = "Regular";
        };
        bold = {
          family = "CaskaydiaMono Nerd Font";
          style = "Bold";
        };
        italic = {
          family = "CaskaydiaMono Nerd Font";
          style = "Italic";
        };
        size = 11;
      };

      terminal = {
        shell = {
          program = "fish";
        };
      };
    }
    // lib.optionalAttrs (!useDms) {
      colors = {
        primary = {
          foreground = "#dcd7ba";
          background = "#1f1f28";
        };

        normal = {
          black = "#090618";
          red = "#c34043";
          green = "#76946a";
          yellow = "#c0a36e";
          blue = "#7e9cd8";
          magenta = "#957fb8";
          cyan = "#6a9589";
          white = "#c8c093";
        };

        bright = {
          black = "#727169";
          red = "#e82424";
          green = "#98bb6c";
          yellow = "#e6c384";
          blue = "#7fb4ca";
          magenta = "#938aa9";
          cyan = "#7aa89f";
          white = "#dcd7ba";
        };
      };
    };
  };
}
