{
  pkgs,
  inputs,
  ...
}:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in
{
  home.packages = [ pkgs-unstable.ghostty ];
  xdg.configFile."ghostty/config".text = ''
    font-family = CaskaydiaMono Nerd Font
    font-size = 11

    # Single-instance: subsequent invocations open a new window in the
    # existing process (analogous to footclient or kitty --single-instance).
    gtk-single-instance = true

    shell-integration = fish
    command = fish

    window-padding-x = 5
    window-padding-y = 5
    # window-theme defaults to "auto" — follows the freedesktop
    # color-scheme preference so GTK chrome flips with system mode.

    # Translucent terminal — cells using the default bg render at this
    # opacity (so wallpaper bleeds through). Cells with explicit bg
    # colors stay fully opaque, which is how tmux's active pane
    # (window-active-style bg=<surface hex>) reads as "solid" while
    # inactive panes (bg=default) fade to wallpaper.
    background-opacity = 0.85
    background-blur-radius = 20

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

    # Auto-switch via freedesktop portal color-scheme. Both themes ship
    # with ghostty — no extra files to manage.
    theme = light:TokyoNight Day,dark:Catppuccin Mocha
  '';
}
