{ ... }:

{
  # Secondary terminal — static Tokyo Night Storm. Alacritty has no
  # native portal-driven theme switching.
  programs.alacritty = {
    enable = true;
    settings = {
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

      colors = {
        primary = {
          foreground = "#c0caf5";
          background = "#24283b";
        };

        cursor = {
          text = "#1d202f";
          cursor = "#c0caf5";
        };

        selection = {
          text = "#c0caf5";
          background = "#2e3c64";
        };

        normal = {
          black = "#1d202f";
          red = "#f7768e";
          green = "#9ece6a";
          yellow = "#e0af68";
          blue = "#7aa2f7";
          magenta = "#bb9af7";
          cyan = "#7dcfff";
          white = "#a9b1d6";
        };

        bright = {
          black = "#414868";
          red = "#f7768e";
          green = "#9ece6a";
          yellow = "#e0af68";
          blue = "#7aa2f7";
          magenta = "#bb9af7";
          cyan = "#7dcfff";
          white = "#c0caf5";
        };
      };
    };
  };
}
