{
  pkgs,
  lib,
  useDms ? false,
  ...
}:

# Matugen integration for the desktop chrome.
#
# Terminals (ghostty/kitty/alacritty/foot), the editor (neovim), and the
# TUI tools that run inside them (tmux, k9s, fzf, etc.) are now pinned to
# the static Catppuccin palette — Mocha for dark, Latte for light. The
# matugen-derived dank16 palette was visually inconsistent across modes
# and added an extra reload step on every wallpaper change. See the
# per-tool nix modules under home/desktop/ and home/cli/.
#
# Matugen still drives the wallpaper-derived chrome (waybar pills)
# because that's where Material You's tonal palettes actually look
# good — and they aren't bound to any text-readability constraints the
# way a terminal palette is. The launcher (fuzzel) used to be on this
# list but was moved to a static Catppuccin Mocha/Latte pair (see
# home/desktop/fuzzel.nix) for consistency with the rest of the stack.
#
# DMS picks up these templates automatically because
# `runUserMatugenTemplates = true`. Paths must be absolute since DMS
# invokes matugen from /tmp.
lib.mkIf useDms {
  home.packages = [ pkgs.matugen ];

  xdg.configFile = {
    "matugen/config.toml".text = ''
      [config]
      reload_apps = true

      [config.wallpaper]
      command = "true"
      arguments = []
      set = false

      [templates.waybar]
      input_path  = "~/.config/matugen/templates/waybar.css"
      output_path = "~/.config/waybar/colors-matugen.css"
      post_hook   = "systemctl --user is-active --quiet wl-waybar && systemctl --user restart wl-waybar; true"
    '';

    "matugen/templates/waybar.css".text = ''
      @define-color m_bg          {{colors.surface.default.hex}};
      @define-color m_dim         {{colors.surface_dim.default.hex}};
      @define-color m_fg          {{colors.on_surface.default.hex}};
      @define-color m_primary     {{colors.primary.default.hex}};
      @define-color m_secondary   {{colors.secondary.default.hex}};
      @define-color m_tertiary    {{colors.tertiary.default.hex}};
      @define-color m_error       {{colors.error.default.hex}};
      @define-color m_outline     {{colors.outline.default.hex}};
      @define-color m_on_primary  {{colors.on_primary.default.hex}};

      * { color: @m_fg; }

      #workspaces { background-color: @m_dim; }
      #workspaces button.active   { background: @m_primary;   color: @m_on_primary; }
      #workspaces button.focused  { background: @m_secondary; color: @m_bg; }
      #workspaces button.urgent   { background: @m_error;     color: @m_fg; }

      #window      { background-color: @m_dim; color: @m_fg; }
      #clock       { background-color: @m_dim; color: @m_fg; }
      #tray        { background-color: @m_dim; color: @m_fg; }

      #cpu         { background-color: @m_primary;   color: @m_bg; }
      #memory      { background-color: @m_secondary; color: @m_bg; }
      #disk        { background-color: @m_tertiary;  color: @m_bg; }
      #custom-uptime { background-color: @m_primary; color: @m_bg; }

      #network            { background-color: @m_tertiary;  color: @m_bg; }
      #network.disconnected { background-color: @m_error;   color: @m_fg; }

      #pulseaudio         { background-color: @m_secondary; color: @m_bg; }
      #pulseaudio.muted   { background-color: @m_outline;   color: @m_fg; }

      #idle_inhibitor          { background-color: @m_tertiary; color: @m_bg; }
      #idle_inhibitor.activated { background-color: @m_primary; color: @m_bg; }

      #privacy            { background-color: @m_error;     color: @m_fg; }
      #battery            { background-color: @m_tertiary;  color: @m_bg; }
      #battery.warning    { background-color: @m_secondary; color: @m_bg; }
      #battery.critical   { background-color: @m_error;     color: @m_fg; }
    '';

  };
}
