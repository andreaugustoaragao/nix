{
  pkgs,
  lib,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  mocha = {
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
  latte = {
    foreground = "#4c4f69";
    background = "#eff1f5";
    selection_foreground = "#4c4f69";
    selection_background = "#ccd0da";
    cursor = "#dc8a78";
    cursor_text_color = "#eff1f5";
    url_color = "#1e66f5";
    color0 = "#5c5f77";
    color8 = "#6c6f85";
    color1 = "#d20f39";
    color9 = "#d20f39";
    color2 = "#40a02b";
    color10 = "#40a02b";
    color3 = "#df8e1d";
    color11 = "#df8e1d";
    color4 = "#1e66f5";
    color12 = "#1e66f5";
    color5 = "#ea76cb";
    color13 = "#ea76cb";
    color6 = "#179299";
    color14 = "#179299";
    color7 = "#acb0be";
    color15 = "#bcc0cc";
  };
  themeText =
    colors:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "${name} ${value}") colors) + "\n";
in
{
  # Kitty is a secondary terminal (ghostty is daily-driver).
  # Binary: nixpkgs on Linux, Homebrew cask on macOS (machines.toml).
  # The cask is notarized and lands in /Applications; this module owns
  # ~/.config/kitty/kitty.conf and the auto theme files on both platforms.
  programs.kitty = {
    enable = true;
    package = if isLinux then pkgs.kitty else null;
    font = {
      name = "CaskaydiaMono Nerd Font";
      size = 11;
    };
    settings = {
      # Dock and Spotlight launches on macOS do not see the nix profile,
      # so a bare `fish` resolves to nothing. Same constraint as Ghostty's
      # `command` in home/desktop/ghostty.nix.
      shell = if isLinux then "fish" else "${pkgs.fish}/bin/fish";
      window_padding_width = 5;
      background_opacity = "0.98";
      confirm_os_window_close = 0;
      wayland_enable_ime = "no";
      update_check_interval = 0;
    };
  };

  # Kitty selects these files from the OS color-scheme preference and
  # updates open windows when the portal changes. DMS/darkman publish
  # prefer-light and prefer-dark; retain Mocha for no preference.
  xdg.configFile = {
    "kitty/dark-theme.auto.conf".text = themeText mocha;
    "kitty/light-theme.auto.conf".text = themeText latte;
    "kitty/no-preference-theme.auto.conf".text = themeText mocha;
  };
}
