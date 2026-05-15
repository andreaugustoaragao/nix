{ ... }:

{
  # Kitty is a secondary terminal (ghostty is daily-driver). Static Tokyo
  # Night Storm palette only — kitty has no native live light/dark
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

      foreground = "#c0caf5";
      background = "#24283b";
      selection_foreground = "#c0caf5";
      selection_background = "#2e3c64";
      cursor = "#c0caf5";
      cursor_text_color = "#1d202f";
      url_color = "#7dcfff";

      color0 = "#1d202f";
      color8 = "#414868";
      color1 = "#f7768e";
      color9 = "#f7768e";
      color2 = "#9ece6a";
      color10 = "#9ece6a";
      color3 = "#e0af68";
      color11 = "#e0af68";
      color4 = "#7aa2f7";
      color12 = "#7aa2f7";
      color5 = "#bb9af7";
      color13 = "#bb9af7";
      color6 = "#7dcfff";
      color14 = "#7dcfff";
      color7 = "#a9b1d6";
      color15 = "#c0caf5";
    };
  };
}
