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
# Templates here use `.default.` accessors so the rendered colors flip
# between matugen's dark and light palettes when DMS toggles mode (see
# `terminalsAlwaysDark = false` in quickshell.nix). TUI tools running
# inside terminals stay consistent with the terminal palette.
#
# This module fills the gaps DMS doesn't cover:
#   - waybar   (write a colors.css for @import)
#   - fuzzel   (write the full ini — no include directive)
#   - foot     (write a colors-only include — DMS's foot template emits
#              only `[colors-dark]` so light mode falls back to defaults)
#   - tmux     (write a status-bar style block)
#   - yazi     (write a theme.toml — yazi reloads on restart)
#   - k9s      (write a skin yaml — referenced from k9s/config.yaml)
#   - bottom   (write the whole bottom.toml — no include directive)
#   - lazygit  (write gui.theme — lazygit deep-merges with defaults)
#   - fzf      (write opts.conf — read via FZF_DEFAULT_OPTS_FILE on every run)
#
# mako is intentionally omitted: under DMS it's not installed and DMS
# owns notifications natively.
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

      [templates.fuzzel]
      input_path  = "~/.config/matugen/templates/fuzzel.ini"
      output_path = "~/.config/fuzzel/fuzzel.ini"
      # fuzzel re-reads on next launch

      [templates.foot]
      input_path  = "~/.config/matugen/templates/foot.ini"
      output_path = "~/.config/foot/colors-matugen.ini"
      # foot re-reads color sections on freedesktop color-scheme change;
      # new windows pick up palette swaps from matugen on next launch.

      [templates.ghostty-dark]
      input_path  = "~/.config/matugen/templates/ghostty-dark.conf"
      output_path = "~/.config/ghostty/themes/dankcolors-dark"
      # Always-dark variant. Paired with ghostty-light below and
      # `theme = dark:dankcolors-dark,light:dankcolors-light` in
      # ghostty/config so ghostty live-switches with the portal.

      [templates.ghostty-light]
      input_path  = "~/.config/matugen/templates/ghostty-light.conf"
      output_path = "~/.config/ghostty/themes/dankcolors-light"

      [templates.tmux]
      input_path  = "~/.config/matugen/templates/tmux.conf"
      output_path = "~/.config/tmux/colors-matugen.conf"
      post_hook   = "tmux source-file ~/.config/tmux/tmux.conf 2>/dev/null && tmux refresh-client -S 2>/dev/null; true"

      [templates.yazi]
      input_path  = "~/.config/matugen/templates/yazi.toml"
      output_path = "~/.config/yazi/theme.toml"
      # yazi reloads its theme on restart; no live signal-reload available.

      [templates.k9s]
      input_path  = "~/.config/matugen/templates/k9s.yaml"
      output_path = "~/.config/k9s/skins/matugen.yaml"
      # k9s reads the skin on launch; restart for new colors.

      [templates.bottom]
      input_path  = "~/.config/matugen/templates/bottom.toml"
      output_path = "~/.config/bottom/bottom.toml"
      # bottom (btm) re-reads the config on launch.

      [templates.lazygit]
      input_path  = "~/.config/matugen/templates/lazygit.yml"
      output_path = "~/.config/lazygit/config.yml"
      # lazygit re-reads the config on launch.

      [templates.fzf]
      input_path  = "~/.config/matugen/templates/fzf.conf"
      output_path = "~/.config/fzf/opts.conf"
      # fzf reads opts on every invocation via FZF_DEFAULT_OPTS_FILE.
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
      # foot palette generated from the current matugen mode. foot.ini
      # in home/desktop/foot.nix `include`s this file. The unsuffixed
      # `[colors]` section is canonical (overrides system color-scheme
      # preference), which is fine here because matugen re-renders this
      # file every time DMS toggles mode.
      [colors]
      alpha=0.98
      foreground={{colors.on_surface.default.hex_stripped}}
      background={{colors.background.default.hex_stripped}}
      selection-foreground={{colors.on_surface.default.hex_stripped}}
      selection-background={{colors.primary_container.default.hex_stripped}}
      cursor={{colors.background.default.hex_stripped}} {{colors.primary.default.hex_stripped}}
      regular0={{dank16.color0.default.hex_stripped}}
      regular1={{dank16.color1.default.hex_stripped}}
      regular2={{dank16.color2.default.hex_stripped}}
      regular3={{dank16.color3.default.hex_stripped}}
      regular4={{dank16.color4.default.hex_stripped}}
      regular5={{dank16.color5.default.hex_stripped}}
      regular6={{dank16.color6.default.hex_stripped}}
      regular7={{dank16.color7.default.hex_stripped}}
      bright0={{dank16.color8.default.hex_stripped}}
      bright1={{dank16.color9.default.hex_stripped}}
      bright2={{dank16.color10.default.hex_stripped}}
      bright3={{dank16.color11.default.hex_stripped}}
      bright4={{dank16.color12.default.hex_stripped}}
      bright5={{dank16.color13.default.hex_stripped}}
      bright6={{dank16.color14.default.hex_stripped}}
      bright7={{dank16.color15.default.hex_stripped}}
    '';

    "matugen/templates/ghostty-dark.conf".text = ''
      # Always-dark ghostty theme. Loaded via `theme = dark:...` in
      # ghostty/config; ghostty switches between this and the light
      # variant when the freedesktop color-scheme preference changes.
      background = {{colors.background.dark.hex}}
      foreground = {{colors.on_surface.dark.hex}}
      cursor-color = {{colors.primary.dark.hex}}
      selection-background = {{colors.primary_container.dark.hex}}
      selection-foreground = {{colors.on_surface.dark.hex}}

      palette = 0={{dank16.color0.dark.hex}}
      palette = 1={{dank16.color1.dark.hex}}
      palette = 2={{dank16.color2.dark.hex}}
      palette = 3={{dank16.color3.dark.hex}}
      palette = 4={{dank16.color4.dark.hex}}
      palette = 5={{dank16.color5.dark.hex}}
      palette = 6={{dank16.color6.dark.hex}}
      palette = 7={{dank16.color7.dark.hex}}
      palette = 8={{dank16.color8.dark.hex}}
      palette = 9={{dank16.color9.dark.hex}}
      palette = 10={{dank16.color10.dark.hex}}
      palette = 11={{dank16.color11.dark.hex}}
      palette = 12={{dank16.color12.dark.hex}}
      palette = 13={{dank16.color13.dark.hex}}
      palette = 14={{dank16.color14.dark.hex}}
      palette = 15={{dank16.color15.dark.hex}}
    '';

    "matugen/templates/ghostty-light.conf".text = ''
      # Always-light ghostty theme — see ghostty-dark.conf.
      background = {{colors.background.light.hex}}
      foreground = {{colors.on_surface.light.hex}}
      cursor-color = {{colors.primary.light.hex}}
      selection-background = {{colors.primary_container.light.hex}}
      selection-foreground = {{colors.on_surface.light.hex}}

      palette = 0={{dank16.color0.light.hex}}
      palette = 1={{dank16.color1.light.hex}}
      palette = 2={{dank16.color2.light.hex}}
      palette = 3={{dank16.color3.light.hex}}
      palette = 4={{dank16.color4.light.hex}}
      palette = 5={{dank16.color5.light.hex}}
      palette = 6={{dank16.color6.light.hex}}
      palette = 7={{dank16.color7.light.hex}}
      palette = 8={{dank16.color8.light.hex}}
      palette = 9={{dank16.color9.light.hex}}
      palette = 10={{dank16.color10.light.hex}}
      palette = 11={{dank16.color11.light.hex}}
      palette = 12={{dank16.color12.light.hex}}
      palette = 13={{dank16.color13.light.hex}}
      palette = 14={{dank16.color14.light.hex}}
      palette = 15={{dank16.color15.light.hex}}
    '';

    "matugen/templates/fuzzel.ini".text = ''
      [main]
      layer=overlay
      width=50
      lines=12
      horizontal-pad=16
      vertical-pad=12
      inner-pad=8
      line-height=22
      icon-theme=Papirus-Dark
      terminal=ghostty -e
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

    "matugen/templates/yazi.toml".text = ''
      # Yazi runs inside the terminal, so its palette follows the same
      # mode the terminal does. Yazi merges this onto its built-in
      # defaults — only the keys that matter visually are overridden
      # here; the rest stay as the package ships them.

      "$schema" = "https://yazi-rs.github.io/schemas/theme.json"

      [mgr]
      cwd          = { fg = "{{colors.primary.default.hex}}" }
      hovered      = { fg = "{{colors.on_primary_container.default.hex}}", bg = "{{colors.primary_container.default.hex}}" }
      preview_hovered = { underline = true }
      find_keyword = { fg = "{{colors.tertiary.default.hex}}", italic = true }
      find_position = { fg = "{{colors.error.default.hex}}", bg = "reset", italic = true }
      marker_copied   = { fg = "{{colors.tertiary.default.hex}}", bg = "{{colors.tertiary.default.hex}}" }
      marker_cut      = { fg = "{{colors.error.default.hex}}",    bg = "{{colors.error.default.hex}}" }
      marker_marked   = { fg = "{{colors.secondary.default.hex}}", bg = "{{colors.secondary.default.hex}}" }
      marker_selected = { fg = "{{colors.primary.default.hex}}",  bg = "{{colors.primary.default.hex}}" }
      count_copied    = { fg = "{{colors.on_tertiary.default.hex}}",  bg = "{{colors.tertiary.default.hex}}" }
      count_cut       = { fg = "{{colors.on_error.default.hex}}",     bg = "{{colors.error.default.hex}}" }
      count_selected  = { fg = "{{colors.on_primary.default.hex}}",   bg = "{{colors.primary.default.hex}}" }
      border_symbol   = "│"
      border_style    = { fg = "{{colors.outline.default.hex}}" }

      [mode]
      normal_main = { fg = "{{colors.on_primary.default.hex}}",   bg = "{{colors.primary.default.hex}}",   bold = true }
      normal_alt  = { fg = "{{colors.primary.default.hex}}",      bg = "{{colors.surface_container_high.default.hex}}" }
      select_main = { fg = "{{colors.on_secondary.default.hex}}", bg = "{{colors.secondary.default.hex}}", bold = true }
      select_alt  = { fg = "{{colors.secondary.default.hex}}",    bg = "{{colors.surface_container_high.default.hex}}" }
      unset_main  = { fg = "{{colors.on_error.default.hex}}",     bg = "{{colors.error.default.hex}}",     bold = true }
      unset_alt   = { fg = "{{colors.error.default.hex}}",        bg = "{{colors.surface_container_high.default.hex}}" }

      [tabs]
      active   = { fg = "{{colors.on_primary.default.hex}}",  bg = "{{colors.primary.default.hex}}" }
      inactive = { fg = "{{colors.on_surface.default.hex}}",  bg = "{{colors.surface_container_high.default.hex}}" }

      [status]
      overall = { bg = "{{colors.surface_container.default.hex}}" }
      sep_left  = { open = "", close = "" }
      sep_right = { open = "", close = "" }
      perm_type  = { fg = "{{colors.primary.default.hex}}" }
      perm_read  = { fg = "{{colors.tertiary.default.hex}}" }
      perm_write = { fg = "{{colors.error.default.hex}}" }
      perm_exec  = { fg = "{{colors.secondary.default.hex}}" }
      perm_sep   = { fg = "{{colors.outline.default.hex}}" }
      progress_label  = { fg = "{{colors.on_surface.default.hex}}", bold = true }
      progress_normal = { fg = "{{colors.primary.default.hex}}",    bg = "{{colors.surface_container.default.hex}}" }
      progress_error  = { fg = "{{colors.error.default.hex}}",      bg = "{{colors.surface_container.default.hex}}" }

      [input]
      border  = { fg = "{{colors.outline.default.hex}}" }
      title   = {}
      value   = {}
      selected = { reversed = true }

      [pick]
      border    = { fg = "{{colors.outline.default.hex}}" }
      active    = { fg = "{{colors.primary.default.hex}}", bold = true }
      inactive  = {}

      [confirm]
      border  = { fg = "{{colors.outline.default.hex}}" }
      title   = { fg = "{{colors.primary.default.hex}}" }
      content = {}
      list    = {}
      btn_yes = { reversed = true }
      btn_no  = {}
      btn_labels = ["[Y]es", "[N]o"]

      [tasks]
      border  = { fg = "{{colors.outline.default.hex}}" }
      title   = {}
      hovered = { fg = "{{colors.primary.default.hex}}", underline = true }

      [which]
      mask           = { bg = "{{colors.surface_container.default.hex}}" }
      cand           = { fg = "{{colors.tertiary.default.hex}}" }
      rest           = { fg = "{{colors.outline.default.hex}}" }
      desc           = { fg = "{{colors.secondary.default.hex}}" }
      separator      = "  "
      separator_style = { fg = "{{colors.outline_variant.default.hex}}" }

      [help]
      on      = { fg = "{{colors.tertiary.default.hex}}" }
      run     = { fg = "{{colors.primary.default.hex}}" }
      desc    = { fg = "{{colors.on_surface.default.hex}}" }
      hovered = { bg = "{{colors.primary_container.default.hex}}", bold = true }
      footer  = { fg = "{{colors.surface.default.hex}}", bg = "{{colors.on_surface.default.hex}}" }

      [notify]
      title_info = { fg = "{{colors.primary.default.hex}}" }
      title_warn = { fg = "{{colors.secondary.default.hex}}" }
      title_error = { fg = "{{colors.error.default.hex}}" }
    '';

    "matugen/templates/tmux.conf".text = ''
      # tmux follows the active matugen palette via `.default.` so its
      # status bar matches the surrounding terminal in either mode.
      # Reload running tmux sessions with `tmux source-file
      # ~/.config/tmux/tmux.conf` (matugen does this in post_hook).

      # Status bar
      set -g status-style 'bg={{colors.surface.default.hex}},fg={{colors.on_surface.default.hex}}'

      # Active window pill
      set -g window-status-current-format '#[fg={{colors.on_primary.default.hex}},bold,bg={{colors.primary.default.hex}}]#(tmux-window-icons #W)#{?window_zoomed_flag,(),}'

      # Inactive window
      set -g window-status-format '#[fg={{colors.outline.default.hex}},bg=default]#(tmux-window-icons #W)'

      # Last (recently visited) window
      set -g window-status-last-style 'fg={{colors.on_surface.default.hex}},bg=default'

      # Status-left session name
      set -g status-left "#[fg={{colors.primary.default.hex}},bold,bg=default] #S "

      # Status-right (clock + tools)
      set -g status-right "#(tmux-right-status)#[fg={{colors.primary.default.hex}}] 󱑒 %a %b %d %l:%M %p"

      # Pane borders
      set -g pane-border-style "fg={{colors.outline.default.hex}}"
      set -g pane-active-border-style "fg={{colors.primary.default.hex}}"

      # Inactive panes use bg=default so they inherit ghostty's
      # background-opacity (0.85) and the wallpaper bleeds through.
      # The active pane sets an explicit surface bg, which the terminal
      # renders fully opaque — so it stands out as "solid" against the
      # see-through inactive ones.
      set -g window-style "fg={{colors.outline.default.hex}},bg=default"
      set -g window-active-style "fg=default,bg={{colors.surface.default.hex}}"

      # Message line
      set -g message-style "fg={{colors.on_surface.default.hex}},bg={{colors.surface_container_high.default.hex}}"
    '';

    "matugen/templates/k9s.yaml".text = ''
      # K9s skin generated from the active matugen palette. Active skin
      # is selected via ~/.config/k9s/config.yaml (k9s.ui.skin =
      # "matugen"); k9s reads the skin on launch, so restart for new
      # colors after a mode toggle.
      k9s:
        body:
          fgColor:    "{{colors.on_surface.default.hex}}"
          bgColor:    "{{colors.surface.default.hex}}"
          logoColor:  "{{colors.primary.default.hex}}"
        prompt:
          fgColor:      "{{colors.on_surface.default.hex}}"
          bgColor:      "{{colors.surface.default.hex}}"
          suggestColor: "{{colors.outline.default.hex}}"
        info:
          fgColor:      "{{colors.secondary.default.hex}}"
          sectionColor: "{{colors.on_surface_variant.default.hex}}"
        dialog:
          fgColor:            "{{colors.on_surface.default.hex}}"
          bgColor:            "{{colors.surface.default.hex}}"
          buttonFgColor:      "{{colors.on_primary.default.hex}}"
          buttonBgColor:      "{{colors.primary.default.hex}}"
          buttonFocusFgColor: "{{colors.on_secondary.default.hex}}"
          buttonFocusBgColor: "{{colors.secondary.default.hex}}"
          labelFgColor:       "{{colors.tertiary.default.hex}}"
          fieldFgColor:       "{{colors.on_surface.default.hex}}"
        frame:
          border:
            fgColor:    "{{colors.outline.default.hex}}"
            focusColor: "{{colors.primary.default.hex}}"
          menu:
            fgColor:     "{{colors.on_surface.default.hex}}"
            keyColor:    "{{colors.tertiary.default.hex}}"
            numKeyColor: "{{colors.primary.default.hex}}"
          crumbs:
            fgColor:     "{{colors.on_primary.default.hex}}"
            bgColor:     "{{colors.primary.default.hex}}"
            activeColor: "{{colors.on_secondary.default.hex}}"
          status:
            newColor:       "{{colors.primary.default.hex}}"
            modifyColor:    "{{colors.tertiary.default.hex}}"
            addColor:       "{{colors.primary.default.hex}}"
            pendingColor:   "{{colors.secondary.default.hex}}"
            errorColor:     "{{colors.error.default.hex}}"
            highlightColor: "{{colors.secondary.default.hex}}"
            killColor:      "{{colors.error.default.hex}}"
            completedColor: "{{colors.on_surface_variant.default.hex}}"
          title:
            fgColor:        "{{colors.on_surface.default.hex}}"
            bgColor:        "{{colors.surface.default.hex}}"
            highlightColor: "{{colors.primary.default.hex}}"
            counterColor:   "{{colors.secondary.default.hex}}"
            filterColor:    "{{colors.tertiary.default.hex}}"
        views:
          charts:
            bgColor: "{{colors.surface.default.hex}}"
            defaultDialColors:
              - "{{colors.primary.default.hex}}"
              - "{{colors.error.default.hex}}"
            defaultChartColors:
              - "{{colors.primary.default.hex}}"
              - "{{colors.error.default.hex}}"
          table:
            fgColor:       "{{colors.on_surface.default.hex}}"
            bgColor:       "{{colors.surface.default.hex}}"
            cursorFgColor: "{{colors.on_primary.default.hex}}"
            cursorBgColor: "{{colors.primary.default.hex}}"
            header:
              fgColor:     "{{colors.tertiary.default.hex}}"
              bgColor:     "{{colors.surface.default.hex}}"
              sorterColor: "{{colors.primary.default.hex}}"
          xray:
            fgColor:         "{{colors.on_surface.default.hex}}"
            bgColor:         "{{colors.surface.default.hex}}"
            cursorColor:     "{{colors.surface_container_high.default.hex}}"
            cursorTextColor: "{{colors.on_surface.default.hex}}"
            graphicColor:    "{{colors.secondary.default.hex}}"
          yaml:
            keyColor:   "{{colors.primary.default.hex}}"
            colonColor: "{{colors.outline.default.hex}}"
            valueColor: "{{colors.on_surface.default.hex}}"
          logs:
            fgColor: "{{colors.on_surface.default.hex}}"
            bgColor: "{{colors.surface.default.hex}}"
            indicator:
              fgColor:        "{{colors.primary.default.hex}}"
              bgColor:        "{{colors.surface.default.hex}}"
              toggleOnColor:  "{{colors.primary.default.hex}}"
              toggleOffColor: "{{colors.outline.default.hex}}"
    '';

    "matugen/templates/bottom.toml".text = ''
      # bottom (btm) styles generated from the active matugen palette.
      # bottom owns this whole file because it has no include directive;
      # add non-style options here as needed.

      [styles.cpu]
      all_entry_color = "{{colors.primary.default.hex}}"
      avg_entry_color = "{{colors.tertiary.default.hex}}"
      nice_color      = "{{colors.secondary.default.hex}}"
      system_color    = "{{colors.error.default.hex}}"
      user_color      = "{{colors.primary.default.hex}}"

      [styles.memory]
      ram_color   = "{{colors.primary.default.hex}}"
      cache_color = "{{colors.secondary.default.hex}}"
      swap_color  = "{{colors.tertiary.default.hex}}"
      arc_color   = "{{colors.error.default.hex}}"

      [styles.network]
      rx_color       = "{{colors.tertiary.default.hex}}"
      tx_color       = "{{colors.primary.default.hex}}"
      rx_total_color = "{{colors.secondary.default.hex}}"
      tx_total_color = "{{colors.outline.default.hex}}"

      [styles.battery]
      high_battery_color   = "{{colors.primary.default.hex}}"
      medium_battery_color = "{{colors.secondary.default.hex}}"
      low_battery_color    = "{{colors.error.default.hex}}"

      [styles.tables]
      headers = { color = "{{colors.tertiary.default.hex}}" }

      [styles.tables.text]
      color = "{{colors.on_surface.default.hex}}"

      [styles.tables.selected_text]
      color    = "{{colors.on_primary.default.hex}}"
      bg_color = "{{colors.primary.default.hex}}"

      [styles.graphs]
      graph_color = "{{colors.outline.default.hex}}"

      [styles.graphs.legend_text]
      color = "{{colors.on_surface.default.hex}}"

      [styles.widgets]
      border_color          = "{{colors.outline.default.hex}}"
      selected_border_color = "{{colors.primary.default.hex}}"

      [styles.widgets.widget_title]
      color = "{{colors.primary.default.hex}}"

      [styles.widgets.text]
      color = "{{colors.on_surface.default.hex}}"

      [styles.widgets.disabled_text]
      color = "{{colors.outline_variant.default.hex}}"
    '';

    "matugen/templates/lazygit.yml".text = ''
      # lazygit theme generated from the active matugen palette. lazygit
      # deep-merges this onto its built-in defaults, so we only set
      # gui.theme — keybindings and other prefs come from upstream.
      gui:
        theme:
          activeBorderColor:
            - "{{colors.primary.default.hex}}"
            - bold
          inactiveBorderColor:
            - "{{colors.outline.default.hex}}"
          optionsTextColor:
            - "{{colors.secondary.default.hex}}"
          selectedLineBgColor:
            - "{{colors.surface_container_high.default.hex}}"
          cherryPickedCommitBgColor:
            - "{{colors.primary_container.default.hex}}"
          cherryPickedCommitFgColor:
            - "{{colors.on_primary_container.default.hex}}"
          unstagedChangesColor:
            - "{{colors.error.default.hex}}"
          defaultFgColor:
            - "{{colors.on_surface.default.hex}}"
          searchingActiveBorderColor:
            - "{{colors.tertiary.default.hex}}"
            - bold
    '';

    "matugen/templates/fzf.conf".text = ''
      # fzf option file from the active matugen palette. The shell exports
      # FZF_DEFAULT_OPTS_FILE pointing at the rendered output, and fzf
      # reads it on every invocation — no reload signal needed.
      --color=fg:{{colors.on_surface.default.hex}},bg:-1,hl:{{colors.tertiary.default.hex}},fg+:{{colors.on_primary.default.hex}},bg+:{{colors.surface_container_high.default.hex}},hl+:{{colors.primary.default.hex}},info:{{colors.secondary.default.hex}},prompt:{{colors.primary.default.hex}},pointer:{{colors.primary.default.hex}},marker:{{colors.tertiary.default.hex}},spinner:{{colors.tertiary.default.hex}},header:{{colors.secondary.default.hex}},border:{{colors.outline.default.hex}}
    '';
  };
}
