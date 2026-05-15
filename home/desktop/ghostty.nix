{
  config,
  pkgs,
  lib,
  inputs,
  useDms ? false,
  ...
}:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  # Install ghostty from unstable packages
  home.packages = [ pkgs-unstable.ghostty ];
  xdg.configFile."ghostty/config".text = ''
    # Font configuration
    font-family = CaskaydiaMono Nerd Font
    font-size = 11

    # Single-instance: subsequent invocations open a new window in the
    # existing process (analogous to footclient or kitty --single-instance).
    gtk-single-instance = true

    # Shell configuration
    shell-integration = fish
    command = fish

    # Window configuration
    window-padding-x = 5
    window-padding-y = 5
    # window-theme defaults to "auto" — follows the freedesktop
    # color-scheme preference so GTK chrome flips with DMS mode.

    # Translucent terminal — cells using the default bg render at this
    # opacity (so wallpaper bleeds through). Cells with explicit bg
    # colors stay fully opaque, which is how tmux's active pane
    # (window-active-style bg=<surface hex>) reads as "solid" while
    # inactive panes (bg=default) fade to wallpaper.
    background-opacity = 0.85
    background-blur-radius = 20

    # Kanagawa color scheme
    background = 1f1f28
    foreground = dcd7ba

    # Cursor colors
    cursor-color = dcd7ba
    cursor-text = 1f1f28

    # Selection colors
    selection-background = 2d4f67
    selection-foreground = dcd7ba

    # Kanagawa color palette
    palette = 0=#090618
    palette = 1=#c34043
    palette = 2=#76946a
    palette = 3=#c0a36e
    palette = 4=#7e9cd8
    palette = 5=#957fb8
    palette = 6=#6a9589
    palette = 7=#c8c093
    palette = 8=#727169
    palette = 9=#e82424
    palette = 10=#98bb6c
    palette = 11=#e6c384
    palette = 12=#7fb4ca
    palette = 13=#938aa9
    palette = 14=#7aa89f
    palette = 15=#dcd7ba

    # Additional settings
    window-decoration = false
    unfocused-split-opacity = 0.9
    copy-on-select = false
    # Close windows/splits without the "are you sure?" prompt.
    confirm-close-surface = false

    # Tame mouse-wheel scroll speed (default 1.0 jumps several lines
    # per notch on high-resolution wheels). 0.4 matches niri's
    # mouse.scroll-factor in this repo.
    mouse-scroll-multiplier = 0.4

    # Full silence: don't ring the bell when long commands finish, and
    # disable every bell-feature so DMS/niri don't get an attention
    # signal that gets routed to the freedesktop alert sound theme.
    notify-on-command-finish-action = no-bell,no-notify
    bell-features = no-system,no-audio,no-attention,no-title,no-border

    ${lib.optionalString useDms "theme = dark:dankcolors-dark,light:dankcolors-light"}
  '';
}
