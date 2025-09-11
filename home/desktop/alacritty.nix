{ config, pkgs, lib, inputs, ... }:

{
  programs.alacritty = {
    enable = true;
    settings = {
      window = {
        opacity = 0.98;  # Match Omarchy opacity
        decorations = "none";  # Disable window decorations
        padding = {
          x = 14;  # Match Omarchy padding
          y = 14;
        };
      };
      
      font = {
        normal = {
          family = "CaskaydiaMono Nerd Font";  # Exact font name from Omarchy
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
        size = 9;  # Match Omarchy font size
      };
      
      terminal = {
        shell = {
          program = "fish";  # Match foot shell
        };
      };
      
      # Kanagawa colors (matching foot configuration)
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