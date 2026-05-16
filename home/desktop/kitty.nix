_:

{
  # Kitty is a secondary terminal (ghostty is daily-driver). Static
  # Catppuccin Mocha palette only — kitty has no native live light/dark
  # switching, but is rarely used so the dark theme is fine on its own.
  programs.kitty = {
    enable = true;
    font = {
      name = "CaskaydiaMono Nerd Font";
      size = 11;
    };
    settings = {
      shell = "fish";
      window_padding_width = 5;
      background_opacity = "0.98";
      confirm_os_window_close = 0;
      wayland_enable_ime = "no";
      update_check_interval = 0;

      foreground = "#cdd6f4";
      background = "#1e1e2e";
      selection_foreground = "#cdd6f4";
      selection_background = "#45475a";
      cursor = "#f5e0dc";
      cursor_text_color = "#1e1e2e";
      url_color = "#89b4fa";

      color0 = "#45475a";
      color8 = "#585b70";
      color1 = "#f38ba8";
      color9 = "#f38ba8";
      color2 = "#a6e3a1";
      color10 = "#a6e3a1";
      color3 = "#f9e2af";
      color11 = "#f9e2af";
      color4 = "#89b4fa";
      color12 = "#89b4fa";
      color5 = "#f5c2e7";
      color13 = "#f5c2e7";
      color6 = "#94e2d5";
      color14 = "#94e2d5";
      color7 = "#bac2de";
      color15 = "#a6adc8";
    };
  };
}
