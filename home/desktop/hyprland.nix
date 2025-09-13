{ config, pkgs, lib, inputs, ... }:

{
  # Hyprland configuration
  wayland.windowManager.hyprland = {
    enable = true;
    
    settings = {
      # Monitor configuration (Omarchy style) - using 2.0 scale
      monitor = [
        # Manual configuration with 2.0 scale:
        ", preferred, auto, 2"
        
        # Previous automatic configuration:
        #", preferred, auto, auto"
        #"Virtual-1,2560x1600@60,0x0,1.600000"
        #",2560x1600@59.97,auto,1"
      ];

      # Startup applications
      exec-once = [
        "uwsm app -- sh -lc 'systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE; dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE'"
        "uwsm app -- swayosd-server"  # OSD for volume/brightness
        "uwsm app -- alacritty --daemon"  # Terminal daemon for faster startup
        "uwsm app -- hyprpaper"  # Wallpaper daemon
        "uwsm app -- waybar -c ~/.config/waybar/hyprland-config.json -s ~/.config/waybar/style.css"  # Waybar with Hyprland config
      ];

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
        "HYPRLAND_LOG_WLR,1"  # Enable WLR logging for debugging
        "WLR_RENDERER,vulkan"  # Use Vulkan renderer for better memory management
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
        kb_options = "compose:caps";  # Caps Lock as compose key (Omarchy default)
        kb_rules = "";
        
        # Omarchy keyboard timing (faster repeat)
        repeat_rate = 40;
        repeat_delay = 600;
        
        follow_mouse = 1;
        sensitivity = 0;  # Can increase if needed (Omarchy suggests 0.35)
        
        touchpad = {
          natural_scroll = "no";
          scroll_factor = 0.4;  # Omarchy's optimized scroll speed
        };
      };

      # General settings (Omarchy + Kanagawa)
      general = {
        gaps_in = 5;
        gaps_out = 10;  # Omarchy style smaller outer gaps
        border_size = 2;
        "col.active_border" = "rgb(dcd7ba)";  # Kanagawa foreground
        "col.inactive_border" = "rgba(595959aa)";
        layout = "dwindle";
        allow_tearing = true;
        resize_on_border = false;
      };

      # Decoration (Omarchy style)
      decoration = {
        rounding = 10;  # Round borders
        
        shadow = {
          enabled = true;
          range = 4;
          render_power = 3;
          color = "rgba(1a1a1aee)";
        };
        
        blur = {
          enabled = false;  # Disabled to reduce memory usage
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
          "global, 1, 8, default"  # Reduced duration
          "windows, 1, 3, easeOutQuint"  # Simplified
          "windowsOut, 1, 1, linear"
          "fade, 1, 2, linear"  # Simplified fade
          "workspaces, 1, 4, easeOutQuint, slide"  # Reduced duration
        ];
      };

      # Layout (Omarchy style)
      dwindle = {
        pseudotile = true;
        preserve_split = true;
        force_split = 2;  # Always split on the right
      };
      
      master = {
        new_status = "master";
      };
      
      misc = {
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        focus_on_activate = true;
        # Memory optimization settings
        vfr = true;  # Variable refresh rate to reduce redraws
        vrr = 1;     # Enable VRR if supported
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
      ];

      # Key bindings (Omarchy style)
      "$mainMod" = "SUPER";
      bind = [
        # Applications (matching Omarchy exactly)
        "$mainMod, Return, exec, alacritty msg create-window --working-directory ~"  # Terminal (new window via daemon)
        "$mainMod, F, exec, thunar"                                 # File manager  
        "$mainMod, B, exec, qutebrowser"                                # Qutebrowser
        "$mainMod, M, exec, spotify"                                # Music
        "$mainMod, N, exec, notes"                              # Notes manager
        "$mainMod, G, exec, brave --app=https://web.whatsapp.com"  # WhatsApp
        "$mainMod, T, exec, firefox -P app --new-window https://teams.microsoft.com" # Microsoft Teams
        "$mainMod, backslash, exec, bitwarden"                      # Password manager
        "$mainMod, A, exec, brave --app=https://grok.com"          # Grok AI
        "$mainMod, X, exec, brave --app=https://x.com"             # X.com
        "$mainMod, O, exec, web-apps-launcher"                         # Web Apps Launcher
        "$mainMod, S, exec, alacritty msg create-window -e btop"   # System monitor
        
        # Menus (Omarchy style)
        "$mainMod, Space, exec, wofi --show drun"                   # Launch apps
        "$mainMod ALT, Space, exec, alacritty msg create-window"   # Omarchy menu (using terminal)
        "$mainMod, Escape, exec, wlogout"                           # Power menu
        
        # Window management (exact Omarchy bindings)
        "$mainMod, W, killactive,"                                  # Close active window
        "$mainMod SHIFT, Q, exit,"                                  # Exit Hyprland
        "SHIFT, F9, fullscreen, 0"                                  # True full screen
        "SHIFT, F11, fullscreen, 0"                                 # Force full screen
        "SHIFT, F10, fullscreen, 1"                                 # Fake full screen
        "$mainMod, J, togglesplit,"                                 # Toggle split
        "$mainMod, P, pseudo,"                                      # Pseudo window
        "$mainMod, V, togglefloating,"                              # Toggle floating
        
        # Move focus with arrow keys and vim keys
        "$mainMod, left, movefocus, l"
        "$mainMod, right, movefocus, r"
        "$mainMod, up, movefocus, u"
        "$mainMod, down, movefocus, d"
        "$mainMod, h, movefocus, l"
        "$mainMod, j, movefocus, d"
        "$mainMod, k, movefocus, u"
        "$mainMod, l, movefocus, r"
        
        # Switch workspaces with number keys (using keycodes like Omarchy)
        "$mainMod, code:10, workspace, 1"                           # Key 1
        "$mainMod, code:11, workspace, 2"                           # Key 2
        "$mainMod, code:12, workspace, 3"                           # Key 3
        "$mainMod, code:13, workspace, 4"                           # Key 4
        "$mainMod, code:14, workspace, 5"                           # Key 5
        "$mainMod, code:15, workspace, 6"                           # Key 6
        "$mainMod, code:16, workspace, 7"                           # Key 7
        "$mainMod, code:17, workspace, 8"                           # Key 8
        "$mainMod, code:18, workspace, 9"                           # Key 9
        "$mainMod, code:19, workspace, 10"                          # Key 0
        
        # Move window to workspace (using keycodes)
        "$mainMod SHIFT, code:10, movetoworkspace, 1"
        "$mainMod SHIFT, code:11, movetoworkspace, 2"
        "$mainMod SHIFT, code:12, movetoworkspace, 3"
        "$mainMod SHIFT, code:13, movetoworkspace, 4"
        "$mainMod SHIFT, code:14, movetoworkspace, 5"
        "$mainMod SHIFT, code:15, movetoworkspace, 6"
        "$mainMod SHIFT, code:16, movetoworkspace, 7"
        "$mainMod SHIFT, code:17, movetoworkspace, 8"
        "$mainMod SHIFT, code:18, movetoworkspace, 9"
        "$mainMod SHIFT, code:19, movetoworkspace, 10"
        
        # Tab between workspaces
        "$mainMod, Tab, workspace, e+1"                             # Next workspace
        "$mainMod SHIFT, Tab, workspace, e-1"                       # Previous workspace
        
        # Swap windows with arrow keys and vim keys
        "$mainMod SHIFT, left, swapwindow, l"
        "$mainMod SHIFT, right, swapwindow, r"
        "$mainMod SHIFT, up, swapwindow, u"
        "$mainMod SHIFT, down, swapwindow, d"
        "$mainMod SHIFT, h, swapwindow, l"
        "$mainMod SHIFT, j, swapwindow, d"
        "$mainMod SHIFT, k, swapwindow, u"
        "$mainMod SHIFT, l, swapwindow, r"
        
        # Resize windows (exact Omarchy keycodes)
        "$mainMod, code:20, resizeactive, -100 0"                   # Minus key: expand left
        "$mainMod, code:21, resizeactive, 100 0"                    # Equal key: shrink left
        "$mainMod SHIFT, code:20, resizeactive, 0 -100"             # Shift+Minus: shrink up
        "$mainMod SHIFT, code:21, resizeactive, 0 100"              # Shift+Equal: expand down
        
        # Alt-Tab window cycling
        "ALT, Tab, cyclenext,"
        "ALT SHIFT, Tab, cyclenext, prev"
        
        # Screenshots (Omarchy style)
        "$mainMod SHIFT, S, exec, screenshot"                      # Region screenshot (selection)
        "$mainMod SHIFT, F, exec, screenshot output"               # Full screen screenshot
        
        # Notification control
        "$mainMod, semicolon, exec, makoctl restore --count 3"    # Show last 3 notifications
        
        # Scroll through workspaces with mouse
        "$mainMod, mouse_down, workspace, e+1"
        "$mainMod, mouse_up, workspace, e-1"
      ];
      
      # Media keys (SIMPLIFIED - using direct commands instead of SwayOSD for minimal setup)
      bindel = [
        # Volume controls (direct commands - no OSD)
        ", XF86AudioRaiseVolume, exec, pamixer -i 5"
        ", XF86AudioLowerVolume, exec, pamixer -d 5" 
        ", XF86AudioMute, exec, pamixer -t"
        ", XF86AudioMicMute, exec, pamixer --default-source -t"
        
        # Brightness controls (direct commands - no OSD)
        ", XF86MonBrightnessUp, exec, brightnessctl set +5%"
        ", XF86MonBrightnessDown, exec, brightnessctl set 5%-"
        
        # Precise 1% adjustments with Alt
        "ALT, XF86AudioRaiseVolume, exec, pamixer -i 1"
        "ALT, XF86AudioLowerVolume, exec, pamixer -d 1"
        "ALT, XF86MonBrightnessUp, exec, brightnessctl set +1%"
        "ALT, XF86MonBrightnessDown, exec, brightnessctl set 1%-"
      ];
      
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