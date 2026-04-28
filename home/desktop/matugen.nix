{
  pkgs,
  lib,
  useDms ? false,
  ...
}:

# Matugen integration. DMS already runs matugen when the wallpaper / theme
# changes (because `runUserMatugenTemplates = true` in dms-settings.json),
# so all this module does is supply a config.toml + per-app templates at
# ~/.config/matugen/. DMS finds them automatically.
#
# Two patterns are used:
#
#   1. Apps that have a native include directive — kitty, ghostty,
#      alacritty, waybar — get a small "colors-matugen.<ext>" file with
#      just the palette. Their main config (still nix-managed) imports it
#      so static colors stay as fallback.
#
#   2. Apps without include support — foot, mako, fuzzel — get their
#      *whole* config rendered by matugen. The corresponding nix module
#      gates its xdg.configFile / programs.<x>.settings on `!useDms` to
#      avoid conflicting with the matugen-owned file.
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

      # ── Apps with include support (matugen writes only colors) ──

      [templates.kitty]
      input_path  = "~/.config/matugen/templates/kitty.conf"
      output_path = "~/.config/kitty/colors-matugen.conf"
      post_hook   = "kill -SIGUSR1 $(pgrep -x kitty) 2>/dev/null || true"

      [templates.ghostty]
      input_path  = "~/.config/matugen/templates/ghostty"
      output_path = "~/.config/ghostty/colors-matugen"
      post_hook   = "pkill -SIGUSR2 ghostty 2>/dev/null || true"

      [templates.alacritty]
      input_path  = "~/.config/matugen/templates/alacritty.toml"
      output_path = "~/.config/alacritty/colors-matugen.toml"
      # alacritty hot-reloads its config via inotify

      [templates.waybar]
      input_path  = "~/.config/matugen/templates/waybar.css"
      output_path = "~/.config/waybar/colors-matugen.css"
      post_hook   = "systemctl --user is-active --quiet wl-waybar && systemctl --user restart wl-waybar; true"

      # ── Apps without include support (matugen owns the full file) ──

      [templates.foot]
      input_path  = "~/.config/matugen/templates/foot.ini"
      output_path = "~/.config/foot/foot.ini"
      post_hook   = "pkill -SIGUSR1 foot 2>/dev/null || true"

      [templates.mako]
      input_path  = "~/.config/matugen/templates/mako"
      output_path = "~/.config/mako/config"
      post_hook   = "makoctl reload 2>/dev/null || true"

      [templates.fuzzel]
      input_path  = "~/.config/matugen/templates/fuzzel.ini"
      output_path = "~/.config/fuzzel/fuzzel.ini"
      # fuzzel re-reads on next launch
    '';

    "matugen/templates/kitty.conf".text = ''
      background           {{colors.surface.default.hex}}
      foreground           {{colors.on_surface.default.hex}}
      cursor               {{colors.primary.default.hex}}
      selection_background {{colors.primary_container.default.hex}}
      selection_foreground {{colors.on_primary_container.default.hex}}

      color0  {{colors.surface_container_lowest.default.hex}}
      color8  {{colors.surface_container_high.default.hex}}
      color1  {{colors.error.default.hex}}
      color9  {{colors.error.default.hex}}
      color2  {{colors.tertiary.default.hex}}
      color10 {{colors.tertiary.default.hex}}
      color3  {{colors.secondary.default.hex}}
      color11 {{colors.secondary.default.hex}}
      color4  {{colors.primary.default.hex}}
      color12 {{colors.primary.default.hex}}
      color5  {{colors.tertiary_container.default.hex}}
      color13 {{colors.tertiary_container.default.hex}}
      color6  {{colors.primary_container.default.hex}}
      color14 {{colors.primary_container.default.hex}}
      color7  {{colors.outline_variant.default.hex}}
      color15 {{colors.on_surface.default.hex}}
    '';

    "matugen/templates/ghostty".text = ''
      background           = {{colors.surface.default.hex_stripped}}
      foreground           = {{colors.on_surface.default.hex_stripped}}
      cursor-color         = {{colors.primary.default.hex_stripped}}
      selection-background = {{colors.primary_container.default.hex_stripped}}
      selection-foreground = {{colors.on_primary_container.default.hex_stripped}}

      palette = 0={{colors.surface_container_lowest.default.hex}}
      palette = 1={{colors.error.default.hex}}
      palette = 2={{colors.tertiary.default.hex}}
      palette = 3={{colors.secondary.default.hex}}
      palette = 4={{colors.primary.default.hex}}
      palette = 5={{colors.tertiary_container.default.hex}}
      palette = 6={{colors.primary_container.default.hex}}
      palette = 7={{colors.outline_variant.default.hex}}
      palette = 8={{colors.surface_container_high.default.hex}}
      palette = 9={{colors.error.default.hex}}
      palette = 10={{colors.tertiary.default.hex}}
      palette = 11={{colors.secondary.default.hex}}
      palette = 12={{colors.primary.default.hex}}
      palette = 13={{colors.tertiary_container.default.hex}}
      palette = 14={{colors.primary_container.default.hex}}
      palette = 15={{colors.on_surface.default.hex}}
    '';

    "matugen/templates/alacritty.toml".text = ''
      [colors.primary]
      background = "{{colors.surface.default.hex}}"
      foreground = "{{colors.on_surface.default.hex}}"

      [colors.cursor]
      cursor = "{{colors.primary.default.hex}}"
      text   = "{{colors.on_primary.default.hex}}"

      [colors.selection]
      background = "{{colors.primary_container.default.hex}}"
      text       = "{{colors.on_primary_container.default.hex}}"

      [colors.normal]
      black   = "{{colors.surface_container_lowest.default.hex}}"
      red     = "{{colors.error.default.hex}}"
      green   = "{{colors.tertiary.default.hex}}"
      yellow  = "{{colors.secondary.default.hex}}"
      blue    = "{{colors.primary.default.hex}}"
      magenta = "{{colors.tertiary_container.default.hex}}"
      cyan    = "{{colors.primary_container.default.hex}}"
      white   = "{{colors.outline_variant.default.hex}}"

      [colors.bright]
      black   = "{{colors.surface_container_high.default.hex}}"
      red     = "{{colors.error.default.hex}}"
      green   = "{{colors.tertiary.default.hex}}"
      yellow  = "{{colors.secondary.default.hex}}"
      blue    = "{{colors.primary.default.hex}}"
      magenta = "{{colors.tertiary_container.default.hex}}"
      cyan    = "{{colors.primary_container.default.hex}}"
      white   = "{{colors.on_surface.default.hex}}"
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

    "matugen/templates/foot.ini".text = ''
      [main]
      font=CaskaydiaMono Nerd Font:size=9
      font-bold=CaskaydiaMono Nerd Font:style=Bold:size=9
      font-italic=CaskaydiaMono Nerd Font:style=Italic:size=9
      dpi-aware=no
      pad=5x5
      shell=fish

      [colors]
      alpha=0.98
      foreground={{colors.on_surface.default.hex_stripped}}
      background={{colors.surface.default.hex_stripped}}

      regular0={{colors.surface_container_lowest.default.hex_stripped}}
      regular1={{colors.error.default.hex_stripped}}
      regular2={{colors.tertiary.default.hex_stripped}}
      regular3={{colors.secondary.default.hex_stripped}}
      regular4={{colors.primary.default.hex_stripped}}
      regular5={{colors.tertiary_container.default.hex_stripped}}
      regular6={{colors.primary_container.default.hex_stripped}}
      regular7={{colors.outline_variant.default.hex_stripped}}

      bright0={{colors.surface_container_high.default.hex_stripped}}
      bright1={{colors.error.default.hex_stripped}}
      bright2={{colors.tertiary.default.hex_stripped}}
      bright3={{colors.secondary.default.hex_stripped}}
      bright4={{colors.primary.default.hex_stripped}}
      bright5={{colors.tertiary_container.default.hex_stripped}}
      bright6={{colors.primary_container.default.hex_stripped}}
      bright7={{colors.on_surface.default.hex_stripped}}
    '';

    "matugen/templates/mako".text = ''
      background-color=#{{colors.surface.default.hex_stripped}}e6
      text-color=#{{colors.on_surface.default.hex_stripped}}
      border-color=#{{colors.outline.default.hex_stripped}}

      anchor=top-right
      width=400
      height=110
      margin=10
      padding=15
      border-size=2
      border-radius=8

      default-timeout=10000

      [mode=do-not-disturb]
      invisible=1
    '';

    "matugen/templates/fuzzel.ini".text = ''
      [main]
      prompt=
      layer=overlay
      width=50
      lines=12
      horizontal-pad=16
      vertical-pad=12
      inner-pad=8
      line-height=22
      icon-theme=Papirus-Dark
      terminal=alacritty msg create-window -e
      fields=name,generic,comment,categories,filename,keywords

      [colors]
      background={{colors.surface.default.hex_stripped}}f2
      text={{colors.on_surface.default.hex_stripped}}ff
      match={{colors.primary.default.hex_stripped}}ff
      selection={{colors.surface_container_high.default.hex_stripped}}ff
      selection-text={{colors.on_surface.default.hex_stripped}}ff
      selection-match={{colors.primary.default.hex_stripped}}ff
      border={{colors.outline.default.hex_stripped}}ff

      [border]
      width=2
      radius=8
    '';
  };
}
