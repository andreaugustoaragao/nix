{
  pkgs,
  lib,
  useDms ? false,
  lockScreen ? false,
  isVm ? false,
  ...
}:

let
  # Daily-driver terminal selection (see ./default-terminal.nix). VMs
  # fall back to kitty because ghostty's OpenGL renderer needs a GL
  # version the guest 3D driver doesn't expose.
  term = import ./default-terminal.nix { inherit isVm; };

  # DMS Settings window: float + size to match the Niri equivalent.
  dmsWindowRules = lib.optionals useDms [
    "float, class:^(org.quickshell)$, title:^(Settings)$"
    "center, class:^(org.quickshell)$, title:^(Settings)$"
    "size 1200 800, class:^(org.quickshell)$, title:^(Settings)$"
  ];

  # Frosted-glass on the DMS bar (matches niri layer-rule namespace=dms:bar).
  # DMS handles its own backdrop blur for popouts/control-center, so we only
  # need the compositor blur for the bar itself.
  dmsLayerRules = lib.optionals useDms [
    "blur, dms:bar"
  ];

  powerMenuBind =
    if useDms then
      "$mainMod, Escape, exec, dms ipc call powermenu toggle"
    else
      "$mainMod, Escape, exec, wlogout";

  notepadBind =
    if useDms then "$mainMod, N, exec, dms ipc call notepad toggle" else "$mainMod, N, exec, notes";

  # Lock binding (only when lockScreen is enabled).
  lockBind = lib.optionals lockScreen [
    (
      if useDms then
        "$mainMod CTRL, L, exec, dms ipc call lock lock"
      else
        "$mainMod CTRL, L, exec, swaylock -f"
    )
  ];

  # DMS surface toggles. Theme toggle pairs with darkman so the
  # xdg-desktop-portal color-scheme reflects the new mode (DMS skips
  # the gsettings write when matugen is active — see niri.nix).
  dmsSurfaceBinds = lib.optionals useDms [
    "$mainMod, comma, exec, dms ipc call dash toggle overview"
    "$mainMod, period, exec, dms ipc call control-center toggle"
    "$mainMod SHIFT, D, exec, sh -c 'dms ipc call theme toggle; darkman toggle'"
  ];

  # Media keys: DMS shows its own OSD via pipewire monitoring, so call
  # wpctl/brightnessctl directly. Without DMS, route through SwayOSD.
  mediaBindel =
    if useDms then
      [
        ", XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
        ", XF86MonBrightnessUp, exec, brightnessctl set 5%+"
        ", XF86MonBrightnessDown, exec, brightnessctl set 5%-"
        "ALT, XF86AudioRaiseVolume, exec, pamixer -i 1"
        "ALT, XF86AudioLowerVolume, exec, pamixer -d 1"
        "ALT, XF86MonBrightnessUp, exec, brightnessctl set +1%"
        "ALT, XF86MonBrightnessDown, exec, brightnessctl set 1%-"
      ]
    else
      [
        ", XF86AudioRaiseVolume, exec, swayosd-client --output-volume raise"
        ", XF86AudioLowerVolume, exec, swayosd-client --output-volume lower"
        ", XF86AudioMute, exec, swayosd-client --output-volume mute-toggle"
        ", XF86AudioMicMute, exec, pamixer --default-source -t"
        ", XF86MonBrightnessUp, exec, swayosd-client --brightness raise"
        ", XF86MonBrightnessDown, exec, swayosd-client --brightness lower"
        "ALT, XF86AudioRaiseVolume, exec, pamixer -i 1"
        "ALT, XF86AudioLowerVolume, exec, pamixer -d 1"
        "ALT, XF86MonBrightnessUp, exec, brightnessctl set +1%"
        "ALT, XF86MonBrightnessDown, exec, brightnessctl set 1%-"
      ];
in
{
  # Hyprland configuration
  wayland.windowManager.hyprland = {
    enable = true;
    # 26.05 changed the default from "hyprlang" to "lua"; our config below
    # is written as a structured hyprlang attrset, so pin the old type.
    configType = "hyprlang";

    settings = {
      # Monitor configuration (mirrors home/desktop/niri.nix output blocks).
      # DP-2 is the Dell S2725QS in portrait (left of DP-1); DP-1 is the
      # 32M2V landscape. transform=3 == niri's transform "270" (counter-
      # clockwise 90°). Logical sizes: DP-2 1440×2560, DP-1 3072×1728.
      # Wildcard preserves auto-detection for hp-laptop's eDP-1, etc.
      monitor = [
        "DP-2, 3840x2160@120, 0x0, 1.5, transform, 3"
        "DP-1, 3840x2160@144, 1440x0, 1.25"
        "Virtual-1, preferred, auto, 2.0"
        ", preferred, auto, auto"
      ];

      # Startup applications (others handled by systemd user services).
      # hyprpolkitagent is launched unconditionally even when DMS owns
      # the shell — DMS 1.4.6's PolkitAuthModal logs "Polkit not
      # available — authentication prompts disabled" and registers
      # nothing against polkit. Drop this once Quickshell exposes
      # polkit primitives. Mirrors home/desktop/niri.nix.
      exec-once = [
        "uwsm app -- sh -lc 'systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE; dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE'"
        "uwsm app -- ${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent"
        "uwsm app -- alacritty --daemon" # Terminal daemon for faster startup
      ];
      # DMS is started as a systemd user unit bound to graphical-session.target
      # (see home/desktop/quickshell.nix), so no exec-once entry is needed here.

      # Environment variables (optimized for memory)
      env = [
        "XCURSOR_SIZE,24"
        "HYPRCURSOR_SIZE,24"
        "QT_QPA_PLATFORM,wayland"
        "SDL_VIDEODRIVER,wayland"
        "XDG_SESSION_TYPE,wayland"
        "NIXOS_OZONE_WL,1"
        "WLR_DRM_NO_MODIFIERS,1"
        # Memory optimization environment variables
        "HYPRLAND_LOG_WLR,1" # Enable WLR logging for debugging
        "WLR_RENDERER,vulkan" # Use Vulkan renderer for better memory management
        # fcitx5 input method variables
        "INPUT_METHOD,fcitx"
        "QT_IM_MODULE,fcitx"
        "XMODIFIERS,@im=fcitx"
        "SDL_IM_MODULE,fcitx"
      ];

      # Input configuration (Enhanced Omarchy style)
      input = {
        kb_layout = "us";
        kb_variant = "mac";
        kb_model = "";
        kb_options = "compose:caps"; # Caps Lock as compose key (Omarchy default)
        kb_rules = "";

        # Omarchy keyboard timing (faster repeat)
        repeat_rate = 40;
        repeat_delay = 600;

        follow_mouse = 1;
        sensitivity = 0; # Can increase if needed (Omarchy suggests 0.35)

        touchpad = {
          natural_scroll = "no";
          scroll_factor = 0.4; # Omarchy's optimized scroll speed
        };
      };

      # General settings (Omarchy + Catppuccin)
      general = {
        gaps_in = 5;
        gaps_out = 10; # Omarchy style smaller outer gaps
        border_size = 2;
        "col.active_border" = "rgb(cdd6f4)"; # Catppuccin Mocha text
        "col.inactive_border" = "rgba(595959aa)";
        layout = "master";
        allow_tearing = true;
        resize_on_border = false;
      };

      # Decoration (Omarchy style)
      decoration = {
        rounding = 10; # Round borders

        shadow = {
          enabled = true;
          range = 4;
          render_power = 3;
          color = "rgba(1a1a1aee)";
        };

        blur = {
          enabled = false; # Disabled to reduce memory usage
          size = 3;
          passes = 1;
          vibrancy = 0.1696;
        };
      };

      # Simplified animations to reduce memory usage
      animations = {
        enabled = "yes";

        bezier = [
          "easeOutQuint, 0.23, 1, 0.32, 1"
          "linear, 0, 0, 1, 1"
        ];

        animation = [
          "global, 1, 8, default" # Reduced duration
          "windows, 1, 3, easeOutQuint" # Simplified
          "windowsOut, 1, 1, linear"
          "fade, 1, 2, linear" # Simplified fade
          "workspaces, 1, 4, easeOutQuint, slide" # Reduced duration
        ];
      };

      # Layout (Omarchy style)
      dwindle = {
        pseudotile = true;
        preserve_split = true;
        force_split = 2; # Always split on the right
      };

      master = {
        new_status = "master";
      };

      misc = {
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        focus_on_activate = true;
        # Memory optimization settings
        vfr = true; # Variable refresh rate to reduce redraws
        vrr = 1; # Enable VRR if supported
      };

      # Window rules (Omarchy transparency system)
      windowrule = [
        # Suppress maximize events
        "suppressevent maximize, class:.*"

        # Reduced opacity rules to minimize memory usage
        # "opacity 0.97 0.9, class:.*"  # Disabled to reduce memory usage

        # Fix XWayland dragging issues
        "nofocus,class:^$,title:^$,xwayland:1,floating:1,fullscreen:0,pinned:0"

        # System floating windows
        "float, tag:floating-window"
        "center, tag:floating-window"
        "size 800 600, tag:floating-window"

        # Fullscreen screensaver
        "fullscreen, class:Screensaver"

        # No transparency on media windows (Omarchy exact)
        "opacity 1 1, class:^(zoom|vlc|mpv|org.kde.kdenlive|com.obsproject.Studio|com.github.PintaProject.Pinta|imv|org.gnome.NautilusPreviewer)$"

        # Force chromium-based browsers into tile mode
        "tile, tag:chromium-based-browser"

        # Browser opacity - subtle transparency (Omarchy exact: focused 1.0, unfocused 0.97)
        "opacity 1 0.97, tag:chromium-based-browser"
        "opacity 1 0.97, tag:firefox-based-browser"

        # Video sites should never have opacity applied (Omarchy exact)
        "opacity 1.0 1.0, initialTitle:(youtube\\.com_/|app\\.zoom\\.us_/wc/home)"

        # Steam rules
        "float, class:steam"
        "center, class:steam, title:Steam"
        "opacity 1 1, class:steam"
        "size 1100 700, class:steam, title:Steam"
        "size 460 800, class:steam, title:Friends List"

        # Bitwarden standalone app
        "float, class:Bitwarden"
        "center, class:Bitwarden"
        "size 1000 700, class:Bitwarden"

        # Hide Parallels Shared Clipboard window
        "workspace special:hidden, title:Parallels Shared Clipboard"
      ];

      windowrulev2 = [
        # Float+center Firefox Bitwarden extension window by title
        "float, title:^(Extension: \(Bitwarden Password Manager\) - Bitwarden — Mozilla Firefox)$"
        "center, title:^(Extension: \(Bitwarden Password Manager\) - Bitwarden — Mozilla Firefox)$"
        # Float MainPicker window
        "float, title:^(MainPicker)$"
        "center, title:^(MainPicker)$"
        # Tag assignments
        "tag +floating-window, class:(blueberry.py|Impala|Wiremix|org.gnome.NautilusPreviewer|com.gabm.satty|Omarchy|About|TUI.float)"
        "tag +floating-window, class:(xdg-desktop-portal-gtk|sublime_text|DesktopEditors), title:^(Open.*Files?|Save.*Files?|Save.*As|All Files|Save)"
        "tag +chromium-based-browser, class:([cC]hrom(e|ium)|[bB]rave-browser|Microsoft-edge|Vivaldi-stable)"
        "tag +firefox-based-browser, class:(Firefox|librewolf)"

        # Audio controls
        "float, class:^(org.pulseaudio.pavucontrol)$"
        "center, class:^(org.pulseaudio.pavucontrol)$"
        "size 800 600, class:^(org.pulseaudio.pavucontrol)$"
      ]
      ++ dmsWindowRules;

      # Layer-shell rules. Currently only used to apply blur to the DMS
      # bar — DMS handles its own backdrop blur for popouts/modals.
      layerrule = dmsLayerRules;

      # Key bindings — mirror home/desktop/niri.nix so muscle memory
      # is identical across compositors. Niri-specific column/tiler
      # actions map to the closest Hyprland equivalent (group ops,
      # fullscreen modes); divergences are flagged inline.
      "$mainMod" = "SUPER";
      bind = [
        # Applications
        "$mainMod, Return, exec, ${term.command}"
        "$mainMod SHIFT, T, exec, thunar"
        "$mainMod SHIFT, B, exec, browser-default"
        "$mainMod SHIFT, M, exec, bookmarks"
        "$mainMod SHIFT, N, exec, notes"
        "$mainMod, backslash, exec, bitwarden"
        "$mainMod SHIFT, A, exec, browser-app https://grok.com"
        "$mainMod SHIFT, X, exec, browser-app https://x.com"
        "$mainMod, S, exec, window-switcher"

        # Launcher
        "$mainMod, Space, exec, fuzzel"
        "$mainMod, D, exec, fuzzel"

        # Window management. Niri: Mod+F = maximize-column (keeps bar),
        # Mod+F9 / Mod+Ctrl+F = fullscreen-window (covers everything).
        # Hyprland: fullscreen,1 = maximize, fullscreen,0 = true fs.
        "$mainMod, W, killactive,"
        "$mainMod SHIFT, Q, exit,"
        "$mainMod, F9, fullscreen, 0"
        "$mainMod CTRL, F, fullscreen, 0"
        "$mainMod, F, fullscreen, 1"
        "$mainMod, V, togglefloating,"

        # Focus (arrows + hjkl). Hyprland's movefocus already falls
        # through to neighbour monitors at workspace edges, matching
        # niri's focus-column-or-monitor-* semantics.
        "$mainMod, left, movefocus, l"
        "$mainMod, right, movefocus, r"
        "$mainMod, up, movefocus, u"
        "$mainMod, down, movefocus, d"
        "$mainMod, h, movefocus, l"
        "$mainMod, l, movefocus, r"
        "$mainMod, k, movefocus, u"
        "$mainMod, j, movefocus, d"

        # Niri: toggle-column-tabbed-display. Closest Hyprland concept
        # is a group (tabbed stack of windows in one slot).
        "$mainMod, c, togglegroup,"

        # Move windows (arrows + hjkl). Niri move-column-*-or-to-
        # monitor-* → Hyprland swapwindow with monitor edge wrap.
        "$mainMod SHIFT, left, swapwindow, l"
        "$mainMod SHIFT, right, swapwindow, r"
        "$mainMod SHIFT, up, swapwindow, u"
        "$mainMod SHIFT, down, swapwindow, d"
        "$mainMod SHIFT, h, swapwindow, l"
        "$mainMod SHIFT, l, swapwindow, r"
        "$mainMod SHIFT, k, swapwindow, u"
        "$mainMod SHIFT, j, swapwindow, d"

        # Niri consume/expel-window-left/right. Hyprland approximation:
        # pull the window into a group (left) or pop it out (right).
        "$mainMod, bracketleft, moveintogroup, l"
        "$mainMod, bracketright, moveoutofgroup,"

        # Multi-monitor (arrows only — Mod+Ctrl+L collides with lock).
        "$mainMod CTRL, left, focusmonitor, l"
        "$mainMod CTRL, right, focusmonitor, r"
        "$mainMod CTRL, up, focusmonitor, u"
        "$mainMod CTRL, down, focusmonitor, d"
        "$mainMod CTRL SHIFT, left, movewindow, mon:l"
        "$mainMod CTRL SHIFT, right, movewindow, mon:r"
        "$mainMod CTRL SHIFT, up, movewindow, mon:u"
        "$mainMod CTRL SHIFT, down, movewindow, mon:d"

        # Workspaces 1..10. Plain digit keys to match niri's layout-
        # aware "Mod+1".."Mod+0" (niri doesn't use keycodes).
        "$mainMod, 1, workspace, 1"
        "$mainMod, 2, workspace, 2"
        "$mainMod, 3, workspace, 3"
        "$mainMod, 4, workspace, 4"
        "$mainMod, 5, workspace, 5"
        "$mainMod, 6, workspace, 6"
        "$mainMod, 7, workspace, 7"
        "$mainMod, 8, workspace, 8"
        "$mainMod, 9, workspace, 9"
        "$mainMod, 0, workspace, 10"

        "$mainMod SHIFT, 1, movetoworkspace, 1"
        "$mainMod SHIFT, 2, movetoworkspace, 2"
        "$mainMod SHIFT, 3, movetoworkspace, 3"
        "$mainMod SHIFT, 4, movetoworkspace, 4"
        "$mainMod SHIFT, 5, movetoworkspace, 5"
        "$mainMod SHIFT, 6, movetoworkspace, 6"
        "$mainMod SHIFT, 7, movetoworkspace, 7"
        "$mainMod SHIFT, 8, movetoworkspace, 8"
        "$mainMod SHIFT, 9, movetoworkspace, 9"
        "$mainMod SHIFT, 0, movetoworkspace, 10"

        "$mainMod, Tab, workspace, e+1"
        "$mainMod SHIFT, Tab, workspace, e-1"

        # Column width / window height. Niri set-column-width ±100 and
        # set-window-height ±100 → Hyprland resizeactive on the X / Y
        # axis. (Niri Mod+R switch-preset-column-width has no native
        # Hyprland equivalent and is intentionally left unbound.)
        "$mainMod, minus, resizeactive, -100 0"
        "$mainMod, equal, resizeactive, 100 0"
        "$mainMod SHIFT, minus, resizeactive, 0 -100"
        "$mainMod SHIFT, equal, resizeactive, 0 100"

        # Screenshots. Niri Mod+Shift+S uses screenshot-niri (niri-
        # native overlay); Hyprland uses the hyprshot-based script.
        "$mainMod SHIFT, S, exec, screenshot"
        "$mainMod SHIFT, F, exec, screenshot output"

        # Notifications
        "$mainMod, semicolon, exec, makoctl restore"

        # Bar toggles (systemd-managed, same scripts as niri.nix)
        "$mainMod, Y, exec, sh -c 'systemctl --user is-active --quiet wl-waybar && systemctl --user stop wl-waybar || systemctl --user start wl-waybar'"
        "$mainMod SHIFT, Y, exec, sh -c 'systemctl --user is-active --quiet wl-eww && systemctl --user stop wl-eww || systemctl --user start wl-eww'"
      ]
      ++ [
        # Power menu / notepad — swap targets when DMS owns the shell.
        powerMenuBind
        notepadBind
      ]
      ++ lockBind
      ++ dmsSurfaceBinds;

      # Media keys: SwayOSD by default, direct wpctl/brightnessctl when
      # DMS owns the OSD (DMS shows its own via pipewire monitoring).
      bindel = mediaBindel;

      # Media control keys
      bindl = [
        ", XF86AudioNext, exec, playerctl next"
        ", XF86AudioPause, exec, playerctl play-pause"
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioPrev, exec, playerctl previous"
      ];

      # Mouse bindings
      bindm = [
        "$mainMod, mouse:272, movewindow"
        "$mainMod, mouse:273, resizewindow"
      ];
    };
  };
}
