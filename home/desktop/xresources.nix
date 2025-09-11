{ config, pkgs, lib, inputs, ... }:

{
  # Xresources configuration with Kanagawa colors and centralized DPI
  xresources = {
    properties = {
      "*.foreground" = "#dcd7ba";
      "*.background" = "#1f1f28";
      "*.cursorColor" = "#dcd7ba";

      "*.color0" = "#16161d";
      "*.color8" = "#727169";

      "*.color1" = "#c34043";
      "*.color9" = "#e82424";

      "*.color2" = "#76946a";
      "*.color10" = "#98bb6c";

      "*.color3" = "#c0a36e";
      "*.color11" = "#e6c384";

      "*.color4" = "#7e9cd8";
      "*.color12" = "#7fb4ca";

      "*.color5" = "#957fb8";
      "*.color13" = "#938aa9";

      "*.color6" = "#6a9589";
      "*.color14" = "#7aa89f";

      "*.color7" = "#c8c093";
      "*.color15" = "#dcd7ba";

      "XTerm*font" = "xft:JetbrainsMono Nerd Font:size=10";
      "XTerm*saveLines" = "100000";
      "XTerm*scrollBar" = "false";
      "XTerm*termName" = "xterm-256color";
      "XTerm*backarrowKey" = "false";
      "XTerm*selectToClipboard" = "true";
      "Xterm.ttyModes" = "erase ^?";
      "Xterm*cursorTheme" = "Bibata-Modern-Classic";
      "XTerm*pointerShape" = "left_ptr";
      "Xft.dpi" = 144;
      "Cairo.dpi" = 144;
      "*.dpi" = 144;
    };
  };
} 