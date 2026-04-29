{
  pkgs,
  lib,
  useDms ? false,
  ...
}:

# Matugen integration for apps DMS doesn't already template.
#
# DMS ships its own templates (in `quickshell/dms/matugen/templates/`)
# for kitty, ghostty, alacritty, foot, neovim, gtk, niri, hyprland,
# qt5ct, qt6ct, firefox, vscode, zed, etc. Those are enabled via
# `matugenTemplate*` settings and DMS runs them automatically. The
# corresponding nix module just needs to load the `dank-*` output files
# DMS writes.
#
# This module fills the gaps DMS doesn't cover:
#   - waybar  (write a colors.css for @import)
#   - mako    (write the full config — no include directive)
#   - fuzzel  (write the full ini — no include directive)
#   - tmux    (write a status-bar style block)
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

      [templates.mako]
      input_path  = "~/.config/matugen/templates/mako"
      output_path = "~/.config/mako/config"
      post_hook   = "makoctl reload 2>/dev/null || true"

      [templates.fuzzel]
      input_path  = "~/.config/matugen/templates/fuzzel.ini"
      output_path = "~/.config/fuzzel/fuzzel.ini"
      # fuzzel re-reads on next launch

      [templates.tmux]
      input_path  = "~/.config/matugen/templates/tmux.conf"
      output_path = "~/.config/tmux/colors-matugen.conf"
      post_hook   = "tmux source-file ~/.config/tmux/tmux.conf 2>/dev/null && tmux refresh-client -S 2>/dev/null; true"

      [templates.yazi]
      input_path  = "~/.config/matugen/templates/yazi.toml"
      output_path = "~/.config/yazi/theme.toml"
      # yazi reloads its theme on restart; no live signal-reload available.
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
      terminal=ghostty -e
      hide-before-typing=true
      filter-desktop=true
      fields=name,generic,keywords

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

    "matugen/templates/yazi.toml".text = ''
      # Yazi runs inside the (always-dark) terminals, so we use the
      # matugen dark palette unconditionally. Yazi merges this onto its
      # built-in defaults — only the keys that matter visually are
      # overridden here; the rest stay as the package ships them.

      "$schema" = "https://yazi-rs.github.io/schemas/theme.json"

      [mgr]
      cwd          = { fg = "{{colors.primary.dark.hex}}" }
      hovered      = { fg = "{{colors.on_primary_container.dark.hex}}", bg = "{{colors.primary_container.dark.hex}}" }
      preview_hovered = { underline = true }
      find_keyword = { fg = "{{colors.tertiary.dark.hex}}", italic = true }
      find_position = { fg = "{{colors.error.dark.hex}}", bg = "reset", italic = true }
      marker_copied   = { fg = "{{colors.tertiary.dark.hex}}", bg = "{{colors.tertiary.dark.hex}}" }
      marker_cut      = { fg = "{{colors.error.dark.hex}}",    bg = "{{colors.error.dark.hex}}" }
      marker_marked   = { fg = "{{colors.secondary.dark.hex}}", bg = "{{colors.secondary.dark.hex}}" }
      marker_selected = { fg = "{{colors.primary.dark.hex}}",  bg = "{{colors.primary.dark.hex}}" }
      count_copied    = { fg = "{{colors.on_tertiary.dark.hex}}",  bg = "{{colors.tertiary.dark.hex}}" }
      count_cut       = { fg = "{{colors.on_error.dark.hex}}",     bg = "{{colors.error.dark.hex}}" }
      count_selected  = { fg = "{{colors.on_primary.dark.hex}}",   bg = "{{colors.primary.dark.hex}}" }
      border_symbol   = "│"
      border_style    = { fg = "{{colors.outline.dark.hex}}" }

      [mode]
      normal_main = { fg = "{{colors.on_primary.dark.hex}}",   bg = "{{colors.primary.dark.hex}}",   bold = true }
      normal_alt  = { fg = "{{colors.primary.dark.hex}}",      bg = "{{colors.surface_container_high.dark.hex}}" }
      select_main = { fg = "{{colors.on_secondary.dark.hex}}", bg = "{{colors.secondary.dark.hex}}", bold = true }
      select_alt  = { fg = "{{colors.secondary.dark.hex}}",    bg = "{{colors.surface_container_high.dark.hex}}" }
      unset_main  = { fg = "{{colors.on_error.dark.hex}}",     bg = "{{colors.error.dark.hex}}",     bold = true }
      unset_alt   = { fg = "{{colors.error.dark.hex}}",        bg = "{{colors.surface_container_high.dark.hex}}" }

      [tabs]
      active   = { fg = "{{colors.on_primary.dark.hex}}",  bg = "{{colors.primary.dark.hex}}" }
      inactive = { fg = "{{colors.on_surface.dark.hex}}",  bg = "{{colors.surface_container_high.dark.hex}}" }

      [status]
      overall = { bg = "{{colors.surface_container.dark.hex}}" }
      sep_left  = { open = "", close = "" }
      sep_right = { open = "", close = "" }
      perm_type  = { fg = "{{colors.primary.dark.hex}}" }
      perm_read  = { fg = "{{colors.tertiary.dark.hex}}" }
      perm_write = { fg = "{{colors.error.dark.hex}}" }
      perm_exec  = { fg = "{{colors.secondary.dark.hex}}" }
      perm_sep   = { fg = "{{colors.outline.dark.hex}}" }
      progress_label  = { fg = "{{colors.on_surface.dark.hex}}", bold = true }
      progress_normal = { fg = "{{colors.primary.dark.hex}}",    bg = "{{colors.surface_container.dark.hex}}" }
      progress_error  = { fg = "{{colors.error.dark.hex}}",      bg = "{{colors.surface_container.dark.hex}}" }

      [input]
      border  = { fg = "{{colors.outline.dark.hex}}" }
      title   = {}
      value   = {}
      selected = { reversed = true }

      [pick]
      border    = { fg = "{{colors.outline.dark.hex}}" }
      active    = { fg = "{{colors.primary.dark.hex}}", bold = true }
      inactive  = {}

      [confirm]
      border  = { fg = "{{colors.outline.dark.hex}}" }
      title   = { fg = "{{colors.primary.dark.hex}}" }
      content = {}
      list    = {}
      btn_yes = { reversed = true }
      btn_no  = {}
      btn_labels = ["[Y]es", "[N]o"]

      [tasks]
      border  = { fg = "{{colors.outline.dark.hex}}" }
      title   = {}
      hovered = { fg = "{{colors.primary.dark.hex}}", underline = true }

      [which]
      mask           = { bg = "{{colors.surface_container.dark.hex}}" }
      cand           = { fg = "{{colors.tertiary.dark.hex}}" }
      rest           = { fg = "{{colors.outline.dark.hex}}" }
      desc           = { fg = "{{colors.secondary.dark.hex}}" }
      separator      = "  "
      separator_style = { fg = "{{colors.outline_variant.dark.hex}}" }

      [help]
      on      = { fg = "{{colors.tertiary.dark.hex}}" }
      run     = { fg = "{{colors.primary.dark.hex}}" }
      desc    = { fg = "{{colors.on_surface.dark.hex}}" }
      hovered = { bg = "{{colors.primary_container.dark.hex}}", bold = true }
      footer  = { fg = "{{colors.surface.dark.hex}}", bg = "{{colors.on_surface.dark.hex}}" }

      [notify]
      title_info = { fg = "{{colors.primary.dark.hex}}" }
      title_warn = { fg = "{{colors.secondary.dark.hex}}" }
      title_error = { fg = "{{colors.error.dark.hex}}" }
    '';

    "matugen/templates/tmux.conf".text = ''
      # tmux follows the *dark* matugen palette unconditionally so it
      # stays consistent with the terminals (which are pinned dark via
      # DMS's terminalsAlwaysDark setting). Otherwise tmux's status bar
      # would flip to the light palette while the surrounding terminal
      # stayed dark, looking incoherent.

      # Status bar — matugen dark palette
      set -g status-style 'bg={{colors.surface.dark.hex}},fg={{colors.on_surface.dark.hex}}'

      # Active window pill
      set -g window-status-current-format '#[fg={{colors.on_primary.dark.hex}},bold,bg={{colors.primary.dark.hex}}]#(tmux-window-icons #W)#{?window_zoomed_flag,(),}'

      # Inactive window
      set -g window-status-format '#[fg={{colors.outline.dark.hex}},bg=default]#(tmux-window-icons #W)'

      # Last (recently visited) window
      set -g window-status-last-style 'fg={{colors.on_surface.dark.hex}},bg=default'

      # Status-left session name
      set -g status-left "#[fg={{colors.primary.dark.hex}},bold,bg=default] #S "

      # Status-right (clock + tools)
      set -g status-right "#(tmux-right-status)#[fg={{colors.primary.dark.hex}}] 󱑒 %a %b %d %l:%M %p"

      # Pane borders
      set -g pane-border-style "fg={{colors.outline.dark.hex}}"
      set -g pane-active-border-style "fg={{colors.primary.dark.hex}}"

      # Inactive panes use bg=default so they inherit ghostty's
      # background-opacity (0.85) and the wallpaper bleeds through.
      # The active pane sets an explicit surface bg, which the terminal
      # renders fully opaque — so it stands out as "solid" against the
      # see-through inactive ones.
      set -g window-style "fg={{colors.outline.dark.hex}},bg=default"
      set -g window-active-style "fg=default,bg={{colors.surface.dark.hex}}"

      # Message line
      set -g message-style "fg={{colors.on_surface.dark.hex}},bg={{colors.surface_container_high.dark.hex}}"
    '';
  };
}
