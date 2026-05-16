_:

{
  # Secondary terminal — static Catppuccin Mocha. Alacritty has no
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
          foreground = "#cdd6f4";
          background = "#1e1e2e";
        };

        cursor = {
          text = "#1e1e2e";
          cursor = "#f5e0dc";
        };

        selection = {
          text = "#cdd6f4";
          background = "#45475a";
        };

        normal = {
          black = "#45475a";
          red = "#f38ba8";
          green = "#a6e3a1";
          yellow = "#f9e2af";
          blue = "#89b4fa";
          magenta = "#f5c2e7";
          cyan = "#94e2d5";
          white = "#bac2de";
        };

        bright = {
          black = "#585b70";
          red = "#f38ba8";
          green = "#a6e3a1";
          yellow = "#f9e2af";
          blue = "#89b4fa";
          magenta = "#f5c2e7";
          cyan = "#94e2d5";
          white = "#a6adc8";
        };
      };
    };
  };
}
