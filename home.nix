{ config, pkgs, lib, inputs, ... }:

{
  # Import LazyVim configuration
  imports = [
    ./nvim-lazyvim.nix
    ./polybar.nix
  ];
  
  home.username = "aragao";
  home.homeDirectory = "/home/aragao";
  home.stateVersion = "24.11";  # Auto-rebuild test

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # Hyprland configuration
  wayland.windowManager.hyprland = {
    enable = true;
    package = inputs.hyprland.packages.${pkgs.system}.hyprland;
    
    settings = {
      # Monitor configuration (Omarchy style)
      monitor = [
        #"Virtual-1,2560x1600@60,0x0,1.600000"
        #", preferred, auto, auto"
        ",2560x1600@59.97,auto,1"
      ];

      # Startup applications (minimized for faster startup)
      exec-once = [
        # "uwsm app -- swayosd-server"  # DISABLED - OSD for volume/brightness (re-enable if you want visual feedback)
        # "uwsm app -- mako"  # DISABLED - Notification daemon
        # "uwsm app -- fcitx5"  # DISABLED - Input method (re-enable if you need non-English input)
        # "uwsm app -- foot --server"  # DISABLED - Terminal server (terminals will start individually)
        # "uwsm app -- hyprpaper"  # DISABLED - Wallpaper daemon (using solid color instead)
      ];

      # Environment variables (minimized - fcitx5 variables removed since it's disabled)
      env = [
        "XCURSOR_SIZE,24"
        "HYPRCURSOR_SIZE,24"  # Omarchy also sets this for Hyprland cursor support
        "WLR_NO_HARDWARE_CURSORS,1"  # Disable hardware cursors to reduce extra planes
        "QT_QPA_PLATFORM,wayland"
        "SDL_VIDEODRIVER,wayland"
        "XDG_SESSION_TYPE,wayland"
        # "NIXOS_OZONE_WL,1"  # Prefer Wayland for Electron/Chromium apps - DISABLED for X11/DWM compatibility
        "WLR_DRM_NO_MODIFIERS,1"  # Reduce DMABUF modifier usage (virtio/Parallels friendly)
        # fcitx5 input method variables (DISABLED since fcitx5 is disabled)
        # "INPUT_METHOD,fcitx"
        # "QT_IM_MODULE,fcitx"
        # "XMODIFIERS,@im=fcitx"
        # "SDL_IM_MODULE,fcitx"
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
          enabled = false;
          range = 2;
          render_power = 3;
          color = "rgba(1a1a1aee)";
        };
        
        blur = {
          enabled = false;
          size = 3;
          passes = 1;
          vibrancy = 0.1696;
        };
      };

      # Animations (Omarchy style)
      animations = {
        enabled = "no";
        
        bezier = [
          "easeOutQuint, 0.23, 1, 0.32, 1"
          "easeInOutCubic, 0.65, 0.05, 0.36, 1"
          "linear, 0, 0, 1, 1"
          "almostLinear, 0.5, 0.5, 0.75, 1.0"
          "quick, 0.15, 0, 0.1, 1"
        ];
        
        animation = [
          "global, 1, 10, default"
          "border, 1, 5.39, easeOutQuint"
          "windows, 1, 4.79, easeOutQuint"
          "windowsIn, 1, 4.1, easeOutQuint, popin 87%"
          "windowsOut, 1, 1.49, linear, popin 87%"
          "fadeIn, 1, 1.73, almostLinear"
          "fadeOut, 1, 1.46, almostLinear"
          "fade, 1, 3.03, quick"
          "layers, 1, 3.81, easeOutQuint"
          "layersIn, 1, 4, easeOutQuint, fade"
          "layersOut, 1, 1.5, linear, fade"
          "fadeLayersIn, 1, 1.79, almostLinear"
          "fadeLayersOut, 1, 1.39, almostLinear"
          "workspaces, 0, 0, ease"
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
      };

      # Window rules (from Omarchy)
      windowrule = [
        # Suppress maximize events
        "suppressevent maximize, class:.*"
        
        # Default opacity for all windows (focused, unfocused)
        "opacity 1 1, class:.*"
        
        # Fix XWayland dragging issues
        "nofocus,class:^$,title:^$,xwayland:1,floating:1,fullscreen:0,pinned:0"
        
        # System floating windows
        "float, tag:floating-window"
        "center, tag:floating-window"
        "size 800 600, tag:floating-window"
        
        # Fullscreen screensaver
        "fullscreen, class:Screensaver"
        
        # No transparency on media windows
        "opacity 1 1, class:^(zoom|vlc|mpv|org.kde.kdenlive|com.obsproject.Studio|com.github.PintaProject.Pinta|imv|org.gnome.NautilusPreviewer)$"
        
        # Force chromium-based browsers into tile mode
        "tile, tag:chromium-based-browser"
        
        # Browser opacity (focused, unfocused)
        "opacity 1 1, tag:chromium-based-browser"
        "opacity 1 1, tag:firefox-based-browser"
        
        # Video sites should have no opacity
        "opacity 1.0 1.0, initialTitle:(youtube\\.com_/|app\\.zoom\\.us_/wc/home)"
        
        # Steam rules
        "float, class:steam"
        "center, class:steam, title:Steam"
        "opacity 1 1, class:steam"
        "size 1100 700, class:steam, title:Steam"
        "size 460 800, class:steam, title:Friends List"
      ];
      
      windowrulev2 = [
        # Tag assignments
        "tag +floating-window, class:(blueberry.py|Impala|Wiremix|org.gnome.NautilusPreviewer|com.gabm.satty|Omarchy|About|TUI.float)"
        "tag +floating-window, class:(xdg-desktop-portal-gtk|sublime_text|DesktopEditors), title:^(Open.*Files?|Save.*Files?|Save.*As|All Files|Save)"
        "tag +chromium-based-browser, class:([cC]hrom(e|ium)|[bB]rave-browser|Microsoft-edge|Vivaldi-stable)"
        "tag +firefox-based-browser, class:(Firefox|zen|librewolf)"
        
        # Original rules
        "float, class:^(pavucontrol)$"
      ];

      # Key bindings (Omarchy style)
      "$mainMod" = "SUPER";
      bind = [
        # Applications (matching Omarchy exactly)
        "$mainMod, Return, exec, footclient"                       # Terminal
        "$mainMod, F, exec, thunar"                                 # File manager  
        "$mainMod, B, exec, brave"                                  # Browser
        "$mainMod, M, exec, spotify"                                # Music
        "$mainMod, N, exec, footclient nvim"                        # Neovim
        "$mainMod, G, exec, signal-desktop"                         # Messenger
        "$mainMod, slash, exec, bitwarden"                          # Password manager
        "$mainMod, A, exec, brave --app=https://grok.com"          # Grok AI
        "$mainMod, X, exec, brave --app=https://x.com"             # X.com
        "$mainMod, S, exec, footclient btop"                       # System monitor
        
        # Menus (Omarchy style)
        "$mainMod, Space, exec, wofi --show drun"                   # Launch apps
        "$mainMod ALT, Space, exec, footclient"                     # Omarchy menu (using terminal)
        "$mainMod, Escape, exec, wlogout"                           # Power menu
        
        # Window management (exact Omarchy bindings)
        "$mainMod, W, killactive,"                                  # Close active window
        "$mainMod SHIFT, Q, exit,"                                  # Exit Hyprland
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
        "$mainMod, semicolon, exec, makoctl restore"               # Show last notification
        
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

  # Sway configuration (DISABLED - redundant with Hyprland)
  wayland.windowManager.sway = {
    enable = false;
    package = null;
    wrapperFeatures.gtk = true;
    wrapperFeatures.base = true;
    
    config = rec {
      # Modifier key
      modifier = "Mod4";  # Super key
      
      # Terminal
      terminal = "footclient";
      
      # Menu
      menu = "wofi --show drun";
      
      # Monitor configuration
      output = {
        "*" = {
          scale = "2";
        };
      };
      
      # Input configuration
      input = {
        "*" = {
          xkb_layout = "us";
          xkb_variant = "mac";
          xkb_options = "compose:caps";  # Caps Lock as compose key
          repeat_rate = "40";
          repeat_delay = "600";
        };
        
        "type:touchpad" = {
          natural_scroll = "disabled";
          scroll_factor = "0.4";
        };
      };
      
      # Startup applications (DISABLED since Sway is disabled)
      # startup = [
      #   { command = "swayosd-server"; }
      #   { command = "mako"; }
      #   { command = "fcitx5"; }
      #   { command = "foot --server"; }
      #   { command = "swaybg -i ${config.home.homeDirectory}/.local/share/wallpapers/1-kanagawa.jpg -m fill"; }
      #   { command = "sway-transparency"; }
      #   { command = "swaymsg workspace 1"; always = true; }
      # ];
      
      # Window appearance
      window = {
        border = 4;
        titlebar = false;
      };
      
      gaps = {
        inner = 5;
        outer = 0;
      };

      focus.newWindow = "focus";
      defaultWorkspace = "workspace number 1";
      
      # Colors (Kanagawa theme)
      colors = {
        focused = {
          border = "#dcd7ba";
          background = "#dcd7ba";
          text = "#1f1f28";
          indicator = "#dcd7ba";
          childBorder = "#dcd7ba";
        };
        focusedInactive = {
          border = "#595959";
          background = "#595959";
          text = "#dcd7ba";
          indicator = "#595959";
          childBorder = "#595959";
        };
        unfocused = {
          border = "#595959";
          background = "#1f1f28";
          text = "#dcd7ba";
          indicator = "#595959";
          childBorder = "#595959";
        };
        urgent = {
          border = "#c34043";
          background = "#c34043";
          text = "#dcd7ba";
          indicator = "#c34043";
          childBorder = "#c34043";
        };
      };
      
      # Bar configuration (waybar handled by systemd service)
      bars = [];
      
      # Key bindings (matching Hyprland)
      keybindings = {
        # Applications
        "${modifier}+Return" = "exec ${terminal}";
        "${modifier}+f" = "exec thunar";
        "${modifier}+b" = "exec brave";
        "${modifier}+m" = "exec spotify";
        "${modifier}+n" = "exec footclient nvim";
        "${modifier}+g" = "exec signal-desktop";
        "${modifier}+slash" = "exec bitwarden";
        "${modifier}+a" = "exec brave --app=https://grok.com";
        "${modifier}+x" = "exec brave --app=https://x.com";
        "${modifier}+s" = "exec footclient btop";
        
        # Menus
        "${modifier}+Space" = "exec ${menu}";
        "${modifier}+Alt+Space" = "exec ${terminal}";
        "${modifier}+Escape" = "exec wlogout";
        
        # Window management
        "${modifier}+w" = "kill";
        "${modifier}+Shift+q" = "exit";
        "Shift+F11" = "fullscreen toggle";
        "Shift+F10" = "fullscreen toggle global";
        "${modifier}+t" = "split toggle";  # Changed from j to t to avoid conflict
        "${modifier}+p" = "floating toggle";
        "${modifier}+v" = "floating toggle";
        
        # Focus movement with arrow keys and vim keys
        "${modifier}+Left" = "focus left";
        "${modifier}+Down" = "focus down";
        "${modifier}+Up" = "focus up";
        "${modifier}+Right" = "focus right";
        "${modifier}+h" = "focus left";
        "${modifier}+j" = "focus down";
        "${modifier}+k" = "focus up";
        "${modifier}+l" = "focus right";
        
        # Window movement with arrow keys and vim keys
        "${modifier}+Shift+Left" = "move left";
        "${modifier}+Shift+Down" = "move down";
        "${modifier}+Shift+Up" = "move up";
        "${modifier}+Shift+Right" = "move right";
        "${modifier}+Shift+h" = "move left";
        "${modifier}+Shift+j" = "move down";
        "${modifier}+Shift+k" = "move up";
        "${modifier}+Shift+l" = "move right";
        
        # Workspace switching
        "${modifier}+1" = "workspace number 1";
        "${modifier}+2" = "workspace number 2";
        "${modifier}+3" = "workspace number 3";
        "${modifier}+4" = "workspace number 4";
        "${modifier}+5" = "workspace number 5";
        "${modifier}+6" = "workspace number 6";
        "${modifier}+7" = "workspace number 7";
        "${modifier}+8" = "workspace number 8";
        "${modifier}+9" = "workspace number 9";
        "${modifier}+0" = "workspace number 10";
        
        # Move window to workspace
        "${modifier}+Shift+1" = "move container to workspace number 1";
        "${modifier}+Shift+2" = "move container to workspace number 2";
        "${modifier}+Shift+3" = "move container to workspace number 3";
        "${modifier}+Shift+4" = "move container to workspace number 4";
        "${modifier}+Shift+5" = "move container to workspace number 5";
        "${modifier}+Shift+6" = "move container to workspace number 6";
        "${modifier}+Shift+7" = "move container to workspace number 7";
        "${modifier}+Shift+8" = "move container to workspace number 8";
        "${modifier}+Shift+9" = "move container to workspace number 9";
        "${modifier}+Shift+0" = "move container to workspace number 10";
        
        # Workspace navigation
        "${modifier}+Tab" = "workspace next";
        "${modifier}+Shift+Tab" = "workspace prev";
        
        # Resize mode
        "${modifier}+minus" = "resize shrink width 100px";
        "${modifier}+equal" = "resize grow width 100px";
        "${modifier}+Shift+minus" = "resize shrink height 100px";
        "${modifier}+Shift+equal" = "resize grow height 100px";
        
        # Screenshots
        "${modifier}+Shift+s" = "exec screenshot";
        "${modifier}+Shift+f" = "exec screenshot output";
        
        # Notifications
        "${modifier}+semicolon" = "exec makoctl restore";
        
        # Media keys (simplified - no OSD)
        "XF86AudioRaiseVolume" = "exec pamixer -i 5";
        "XF86AudioLowerVolume" = "exec pamixer -d 5";
        "XF86AudioMute" = "exec pamixer -t";
        "XF86AudioMicMute" = "exec pamixer --default-source -t";
        "XF86MonBrightnessUp" = "exec brightnessctl set +5%";
        "XF86MonBrightnessDown" = "exec brightnessctl set 5%-";
        "Alt+XF86AudioRaiseVolume" = "exec pamixer -i 1";
        "Alt+XF86AudioLowerVolume" = "exec pamixer -d 1";
        "Alt+XF86MonBrightnessUp" = "exec brightnessctl set +1%";
        "Alt+XF86MonBrightnessDown" = "exec brightnessctl set 1%-";
        
        # Media control
        "XF86AudioNext" = "exec playerctl next";
        "XF86AudioPause" = "exec playerctl play-pause";
        "XF86AudioPlay" = "exec playerctl play-pause";
        "XF86AudioPrev" = "exec playerctl previous";
      };
      
      # Window rules
      window.commands = [
        { criteria = { app_id = "pavucontrol"; }; command = "floating enable"; }
        { criteria = { app_id = "steam"; }; command = "floating enable"; }
        
        # Default transparency for all windows (focused: 95%, unfocused: 85%)
        { criteria = { app_id = ".*"; }; command = "opacity 0.95"; }
        # class criteria removed - using app_id only for Wayland compatibility
        
        # Special opacity rules for specific apps
        { criteria = { app_id = "thunar"; }; command = "opacity 0.95"; }
        { criteria = { app_id = "^(zoom|vlc|mpv)$"; }; command = "opacity 1.0"; }
        
        # Browser transparency
        { criteria = { app_id = "^(brave-browser|[cC]hrom(e|ium)|firefox|zen|librewolf)$"; }; command = "opacity 0.98"; }
      ];
      
      # Workspace assignment
      assigns = {
        "2" = [{ app_id = "brave-browser"; }];
        "3" = [{ app_id = "signal"; }];
      };

    };
    
    extraConfig = ''
      # Additional sway configuration
      
      # Environment variables
      exec_always {
        systemctl --user import-environment DISPLAY WAYLAND_DISPLAY SWAYSOCK XCURSOR_THEME XCURSOR_SIZE
        hash dbus-update-activation-environment 2>/dev/null && \
          dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY SWAYSOCK XCURSOR_THEME XCURSOR_SIZE
      }
      
      # Set cursor theme environment variables
      exec_always {
        export XCURSOR_THEME=Adwaita
        export XCURSOR_SIZE=24
        export WLR_NO_HARDWARE_CURSORS=0
      }
      
      # Cursor theme configuration
      seat seat0 xcursor_theme Adwaita 24
      
      # Focus follows mouse
      focus_follows_mouse yes
      
      # Workspace back and forth
      workspace_auto_back_and_forth yes
      
      # Focus new windows immediately
      for_window [app_id=".*"] focus
      
      # Hide cursor when typing
      seat * hide_cursor when-typing enable
      
      # Configure floating windows
      for_window [app_id="blueberry.py"] floating enable
      for_window [app_id="Wiremix"] floating enable
      for_window [app_id="steam"] floating enable, resize set 1100 700
      for_window [title="Friends List"] floating enable, resize set 460 800
      
      # Configure tiling layout - use default splith/splitv instead of tabbed
      default_orientation auto
      workspace_layout default
      
      # Window transparency configuration
      # Set default opacity for all windows
      # class criteria removed - using app_id only for Wayland compatibility
      for_window [app_id=".*"] opacity 0.85
      
      # Increase opacity for media applications
      for_window [app_id="^(zoom|vlc|mpv)$"] opacity 1.0
      for_window [app_id="^(zoom|vlc|mpv)$"] opacity 1.0
      
      # Dynamic transparency on focus change
      # Note: Sway doesn't have native focus-based opacity like Hyprland
      # This is handled by the windowrule configuration above with dual opacity values
      
    '';
  };

  # X11 i3 Window Manager Configuration
  xsession.windowManager.i3 = {
    enable = true;
    
    package = pkgs.i3-gaps;

    config = rec {
      modifier = "Mod4";
      
      # Terminal and basic applications (matching Hyprland bindings)
      terminal = "st";
      
      # Keybindings matching Hyprland configuration
      keybindings = {
        # Applications (updated per user request)
        "${modifier}+Return" = "exec ${terminal}";
        "${modifier}+f" = "exec thunar";
        "${modifier}+Shift+Return" = "exec brave";  # Changed from b to Shift+Return
        "${modifier}+m" = "exec spotify";
        "${modifier}+n" = "exec ${terminal} -e nvim";
        "${modifier}+g" = "exec signal-desktop";
        "${modifier}+slash" = "exec bitwarden";
        "${modifier}+a" = "exec brave --app=https://grok.com";
        "${modifier}+x" = "exec brave --app=https://x.com";
        "${modifier}+s" = "exec ${terminal} -e btop";
        
        # Menus (matching Hyprland style)
        "${modifier}+space" = "exec rofi -show drun";
        "${modifier}+Alt+space" = "exec ${terminal}";
        "${modifier}+Escape" = "exec i3lock";
        
        # Window management (matching Hyprland exactly)
        "${modifier}+w" = "kill";
        "${modifier}+Shift+q" = "exec i3-msg exit";
        "Shift+F11" = "fullscreen toggle";
        "${modifier}+j" = "split h";
        
        # Focus movement with arrow keys and vim keys (updated per user request)
        "${modifier}+Left" = "focus left";
        "${modifier}+Right" = "focus right";  
        "${modifier}+Up" = "focus up";
        "${modifier}+Down" = "focus down";
        "${modifier}+h" = "focus left";
        "${modifier}+b" = "focus left";    # User requested: cmd+b for focus left
        "${modifier}+v" = "focus down";    # User requested: cmd+v for focus down  
        "${modifier}+k" = "focus up";
        "${modifier}+l" = "focus right";
        
        # Workspace switching (1-10, matching Hyprland)
        "${modifier}+1" = "workspace number 1";
        "${modifier}+2" = "workspace number 2";
        "${modifier}+3" = "workspace number 3";
        "${modifier}+4" = "workspace number 4";
        "${modifier}+5" = "workspace number 5";
        "${modifier}+6" = "workspace number 6";
        "${modifier}+7" = "workspace number 7";
        "${modifier}+8" = "workspace number 8";
        "${modifier}+9" = "workspace number 9";
        "${modifier}+0" = "workspace number 10";
        
        # Move window to workspace (matching Hyprland)
        "${modifier}+Shift+1" = "move container to workspace number 1";
        "${modifier}+Shift+2" = "move container to workspace number 2";
        "${modifier}+Shift+3" = "move container to workspace number 3";
        "${modifier}+Shift+4" = "move container to workspace number 4";
        "${modifier}+Shift+5" = "move container to workspace number 5";
        "${modifier}+Shift+6" = "move container to workspace number 6";
        "${modifier}+Shift+7" = "move container to workspace number 7";
        "${modifier}+Shift+8" = "move container to workspace number 8";
        "${modifier}+Shift+9" = "move container to workspace number 9";
        "${modifier}+Shift+0" = "move container to workspace number 10";
        
        # Tab between workspaces (matching Hyprland)
        "${modifier}+Tab" = "workspace next";
        "${modifier}+Shift+Tab" = "workspace prev";
        
        # Move windows with arrow keys and vim keys (updated to match focus keys)
        "${modifier}+Shift+Left" = "move left";
        "${modifier}+Shift+Right" = "move right";
        "${modifier}+Shift+Up" = "move up";
        "${modifier}+Shift+Down" = "move down";
        "${modifier}+Shift+h" = "move left";
        "${modifier}+Shift+b" = "move left";   # Matches cmd+b for focus left
        "${modifier}+Shift+v" = "move down";   # Matches cmd+v for focus down
        "${modifier}+Shift+k" = "move up";
        "${modifier}+Shift+l" = "move right";
        
        # Resize windows (similar to Hyprland resize bindings)
        "${modifier}+minus" = "resize shrink width 100px";
        "${modifier}+equal" = "resize grow width 100px";
        "${modifier}+Shift+minus" = "resize shrink height 100px";
        "${modifier}+Shift+equal" = "resize grow height 100px";
        
        # Alt-Tab window cycling (matching Hyprland)
        "Alt+Tab" = "focus right";
        "Alt+Shift+Tab" = "focus left";
        
        # Screenshots (matching Hyprland style - using scrot for X11)
        "${modifier}+Shift+s" = "exec scrot -s ~/Pictures/screenshot-%Y-%m-%d_%H-%M-%S.png";
        "${modifier}+Shift+f" = "exec scrot ~/Pictures/screenshot-%Y-%m-%d_%H-%M-%S.png";
        
        # Media keys (matching Hyprland exactly)
        "XF86AudioRaiseVolume" = "exec pamixer -i 5";
        "XF86AudioLowerVolume" = "exec pamixer -d 5";
        "XF86AudioMute" = "exec pamixer -t";
        "XF86AudioMicMute" = "exec pamixer --default-source -t";
        "XF86MonBrightnessUp" = "exec brightnessctl set +5%";
        "XF86MonBrightnessDown" = "exec brightnessctl set 5%-";
      };
      
      floating.criteria = [
        {class = "pavucontrol";}
        {class = "1Password";}
        {class = "Bitwarden";}
        {class = "qutebrowser_edit";}
        {class = "Pinta";}
        {class = "Xdaliclock";}
      ];

      floating.titlebar = false;

      fonts = {
        names = ["RobotoMono"];
        style = "Medium";
        size = 10.0;
      };
      
      bars = [];
      colors = {
        focused = {
          background = "#191724";
          border = "#9ccfd8";
          text = "#e0def4";
          indicator = "#eb6f92";
          childBorder = "#5b96b2";
        };
        "background" = "#191724";
      };
      
      window.border = 4;
      window.titlebar = false;
      gaps = {
        inner = 5;
        outer = 5;
        bottom = 5;
        top = 5;
        left = 5;
        right = 5;
      };

      focus.followMouse = false;
      defaultWorkspace = "workspace number 1";
      
      
      assigns = {
        "1" = [
          {
            class = "Alacritty";
            instance = "default-tmux";
          }
        ];
        "2" = [
          {class = "^firefox$";}
          {
            instance = "chromium-browser";
            class = "Chromium-browser";
          }
          {
            instance = "brave-browser";
            class = "Brave-browser";
          }
        ];
        "3" = [
          {
            instance = "teams.microsoft.com";
            class = "Brave-browser";
          }
          {
            instance = "teams-for-linux";
            class = "teams-for-linux";
          }
        ];
        "4" = [
          {
            instance = "outlook.office.com";
            class = "Brave-browser";
          }
          {
            instance = "mail.google.com";
            class = "Brave-browser";
          }
        ];
        "5" = [{class = "jetbrains-goland";} {class = "jetbrains-idea";}];
        "7" = [
          {
            instance = "music.youtube.com";
            class = "Brave-browser";
          }
          {
            instance = "youtube.com";
            class = "Brave-browser";
          }
          {
            instance = "www.amazon.com__gp_video_storefront";
            class = "Brave-browser";
          }
        ];
        "8" = [
          {
            instance = "chat.openai.com";
            class = "Brave-browser";
          }
        ];
        "10" = [
          {
            instance = "x.com";
            class = "Brave-browser";
          }
          {
            instance = "reddit.com";
            class = "Brave-browser";
          }
          {
            instance = "web.whatsapp.com";
            class = "Brave-browser";
          }
        ];
      };
      focus.newWindow = "focus";
      startup = [
        {
          command = "xset s 600 dpms 1800 1800 1800";
          always = false;
          notification = false;
        }
        {
          command = "xrdb -merge ~/.Xresources";
          always = false;
          notification = false;
        }
        {
          command = "unclutter";
          always = true;
          notification = false;
        }

        {
          command = "xss-lock -n ${pkgs.xsecurelock}/libexec/xsecurelock/dimmer -l -- ${pkgs.xsecurelock}/bin/xsecurelock";
          always = false;
          notification = false;
        }

        {
          command = "i3-msg workspace 1";
          always = false;
          notification = false;
        }
        {
          command = "${pkgs.feh}/bin/feh --no-fehbg --bg-fill ~/.local/share/wallpapers/1-kanagawa.jpg";
          always = true;
          notification = false;
        }
      ];
    };
    extraConfig = ''
      # Center a specific dialog horizontally and position it 45px from the top
      for_window [class="^my-calendar-class$"] floating enable
    '';
  };

  # Notification daemon - Mako (DISABLED for minimal system)
  # services.mako = {
  #   enable = true;
  #   
  #   settings = {
  #     # Omarchy standard dimensions and positioning
  #     width = 420;
  #     height = 110;
  #     padding = "10";
  #     border-size = 2;
  #     font = "Liberation Sans 11";
  #     anchor = "top-right";
  #     margin = "20";
  #     
  #     # Kanagawa theme colors (matching Omarchy exactly)
  #     text-color = "#dcd7ba";       # Kanagawa foreground
  #     border-color = "#dcd7ba";     # Same as text
  #     background-color = "#1f1f28"; # Kanagawa background
  #     
  #     # Notification behavior
  #     default-timeout = 5000;  # 5 seconds
  #     max-icon-size = 32;
  #   };
  # };

  # Notification daemon - Dunst (for X11 only)
  services.dunst = {
    enable = true;
    settings = {
      global = {
        # Omarchy standard dimensions and positioning
        width = 420;
        height = 110;
        origin = "top-right";
        offset = "10x20";
        padding = 10;
        horizontal_padding = 10;
        font = "Liberation Sans 11";
        
        # Notification behavior
        timeout = 5;
        icon_path = "/run/current-system/sw/share/icons/hicolor/scalable/apps:/run/current-system/sw/share/icons/hicolor/48x48/apps";
        max_icon_size = 32;
        
        # Visual appearance
        corner_radius = 5;
        frame_width = 2;
        separator_height = 2;
        sort = true;
        idle_threshold = 120;
        
        # Mouse interaction
        mouse_left_click = "close_current";
        mouse_middle_click = "do_action";
        mouse_right_click = "close_all";
      };
      
      urgency_low = {
        # Kanagawa theme colors (matching Omarchy)
        background = "#1f1f28";
        foreground = "#dcd7ba";
        frame_color = "#54546d";
        timeout = 5;
      };
      
      urgency_normal = {
        background = "#1f1f28";
        foreground = "#dcd7ba";
        frame_color = "#dcd7ba";
        timeout = 5;
      };
      
      urgency_critical = {
        background = "#1f1f28";
        foreground = "#c34043";
        frame_color = "#c34043";
        timeout = 0;
      };
    };
  };


  # Status bar - Waybar (DISABLED for minimal system)
  programs.waybar = {
    enable = false;
    # systemd.enable = true;
    settings = {
      mainBar = {
        reload_style_on_change = true;
        layer = "top";
        position = "top";
        spacing = 0;
        height = 26;
        modules-left = [ "hyprland/workspaces" "sway/workspaces" ];
        modules-center = [ "clock" ];
        modules-right = [
          "group/tray-expander"
          "network"
          "pulseaudio"
          "cpu"
          "memory"
          "disk"
          "battery"
        ];
        
        "hyprland/workspaces" = {
          on-click = "activate";
          format = "{icon}";
          format-icons = {
            default = "";
            "1" = "1";
            "2" = "2";
            "3" = "3";
            "4" = "4";
            "5" = "5";
            "6" = "6";
            "7" = "7";
            "8" = "8";
            "9" = "9";
            active = "󱓻";
          };
          persistent-workspaces = {
            "1" = [];
            "2" = [];
            "3" = [];
            "4" = [];
            "5" = [];
          };
        };
        
        "sway/workspaces" = {
          format = "{icon}";
          format-icons = {
            "1" = "1";
            "2" = "2";
            "3" = "3";
            "4" = "4";
            "5" = "5";
            "6" = "6";
            "7" = "7";
            "8" = "8";
            "9" = "9";
            "10" = "0";
            focused = "󱓻";
            urgent = "";
          };
          persistent-workspaces = {
            "1" = [];
            "2" = [];
            "3" = [];
            "4" = [];
            "5" = [];
          };
          all-outputs = true;
        };
        
        "cpu" = {
          interval = 5;
          format = "󰻠 {usage}%";
          tooltip-format = "CPU Usage: {usage}%";
          on-click = "footclient btop";
        };
        
        "memory" = {
          interval = 5;
          format = "󰍛 {used:0.1f}G ({percentage}%)";
          tooltip-format = "Memory: {used:0.1f}G / {total:0.1f}G ({percentage}%)";
          on-click = "footclient btop";
        };
        
        "disk" = {
          interval = 30;
          format = "󰋊 {used} ({percentage_used}%)";
          path = "/";
          tooltip-format = "Disk: {used} / {total} ({percentage_used}%)";
          on-click = "footclient btop";
        };
        
        "clock" = {
          format = "{:%A %H:%M}";
          format-alt = "{:%d %B W%V %Y}";
          tooltip = false;
        };
        
        "network" = {
          format-icons = ["󰤯" "󰤟" "󰤢" "󰤥" "󰤨"];
          format = "󰀂 {ifname} ⇣{bandwidthDownBytes:>6} ⇡{bandwidthUpBytes:>6}";
          format-wifi = "󰀂 {ifname} ⇣{bandwidthDownBytes:>6} ⇡{bandwidthUpBytes:>6}";
          format-ethernet = "󰀂 {ifname} ⇣{bandwidthDownBytes:>6} ⇡{bandwidthUpBytes:>6}";
          format-disconnected = "󰖪 Disconnected";
          tooltip-format-wifi = "{essid} ({frequency} GHz)\n⇣{bandwidthDownBytes}  ⇡{bandwidthUpBytes}";
          tooltip-format-ethernet = "⇣{bandwidthDownBytes}  ⇡{bandwidthUpBytes}";
          tooltip-format-disconnected = "Disconnected";
          interval = 3;
          spacing = 1;
        };
        
        "battery" = {
          bat = "BAT0";
          adapter = "ADP0";
          format = "{icon} {capacity}%";
          format-discharging = "{icon} {capacity}%";
          format-charging = "{icon} {capacity}%";
          format-plugged = "󰚥 {capacity}%";
          format-icons = {
            charging = ["󰢜" "󰂆" "󰂇" "󰂈" "󰢝" "󰂉" "󰢞" "󰂊" "󰂋" "󰂅"];
            default = ["󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹"];
          };
          format-full = "󰂅 100%";
          tooltip-format-discharging = "{power:>1.0f}W↓ {capacity}%";
          tooltip-format-charging = "{power:>1.0f}W↑ {capacity}%";
          interval = 5;
          states = {
            warning = 20;
            critical = 10;
          };
        };
        
        
        "pulseaudio" = {
          format = "{icon} {volume}%";
          format-muted = "󰝟 {volume}%";
          on-click-right = "pamixer -t";
          tooltip-format = "Volume: {volume}%";
          scroll-step = 5;
          format-icons = {
            default = ["󰕿" "󰖀" "󰕾"];
          };
        };
        
        "group/tray-expander" = {
          orientation = "inherit";
          drawer = {
            transition-duration = 600;
            children-class = "tray-group-item";
          };
          modules = [ "custom/expand-icon" "tray" ];
        };
        
        "custom/expand-icon" = {
          format = "󰞘";
          tooltip = false;
        };
        
        "tray" = {
          icon-size = 12;
          spacing = 12;
        };
      };
      
    };
    
    style = ''
      * {
        background-color: #1f1f28;  /* Kanagawa background */
        color: #dcd7ba;  /* Kanagawa foreground */
        border: none;
        border-radius: 0;
        min-height: 0;
        font-family: CaskaydiaMono Nerd Font;  /* Omarchy exact match */
        font-size: 12px;  /* Omarchy standard */
      }
      
      .modules-left {
        margin-left: 8px;
      }
      
      .modules-right {
        margin-right: 8px;
      }
      
      /* Workspaces styling - minimal, no background */
      #workspaces button {
        all: initial;
        padding: 0 6px;
        margin: 0 1.5px;
        min-width: 9px;
      }
      
      #workspaces button.empty {
        opacity: 0.5;
      }
      
      /* Center modules - no special backgrounds */
      #clock {
        margin-left: 8.75px;
      }
      
      /* Right modules - each with distinct Kanagawa colors */
      #custom-expand-icon {
        background-color: #54546d;  /* Kanagawa surface1 */
        color: #dcd7ba;
        padding: 4px 8px;
        margin: 2px 3px;
        border-radius: 10px;
      }
      
      #tray {
        background-color: #54546d;  /* Kanagawa surface1 */
        color: #dcd7ba;
        padding: 4px 8px;
        margin: 2px 3px;
        border-radius: 10px;
      }
      
      .tray-group-item {
        background-color: #54546d;  /* Kanagawa surface1 */
        color: #dcd7ba;
        padding: 4px 8px;
        margin: 2px 3px;
        border-radius: 10px;
      }
      
      #network {
        background-color: #6a9589;  /* Kanagawa cyan */
        color: #1f1f28;  /* Dark text on cyan background */
        padding: 4px 8px;
        margin: 2px 3px;
        border-radius: 10px;
        min-width: 220px; /* stabilize width for DL/UL */
      }
      
      #pulseaudio {
        background-color: #c0a36e;  /* Kanagawa yellow */
        color: #1f1f28;  /* Dark text on yellow background */
        padding: 4px 8px;
        margin: 2px 3px;
        border-radius: 10px;
      }
      
      #cpu {
        background-color: #e82424;  /* Kanagawa bright red */
        color: #dcd7ba;  /* Light text on red background */
        padding: 4px 8px;
        margin: 2px 3px;
        border-radius: 10px;
      }
      
      #memory {
        background-color: #98bb6c;  /* Kanagawa bright green */
        color: #1f1f28;  /* Dark text on green background */
        padding: 4px 8px;
        margin: 2px 3px;
        border-radius: 10px;
      }
      
      #disk {
        background-color: #7fb4ca;  /* Kanagawa bright blue */
        color: #1f1f28;  /* Dark text on blue background */
        padding: 4px 8px;
        margin: 2px 3px;
        border-radius: 10px;
      }
      
      #battery {
        background-color: #938aa9;  /* Kanagawa bright magenta */
        color: #dcd7ba;  /* Light text on magenta background */
        padding: 4px 8px;
        margin: 2px 3px;
        border-radius: 10px;
      }
      
      /* Special battery states */
      #battery.warning {
        background-color: #e6c384;  /* Kanagawa bright yellow */
        color: #1f1f28;
      }
      
      #battery.critical {
        background-color: #c34043;  /* Kanagawa red */
        color: #dcd7ba;
        animation: blink 1s linear infinite;
      }
      
      @keyframes blink {
        to {
          opacity: 0.5;
        }
      }
      
      tooltip {
        background-color: #2a2a37;  /* Kanagawa darker surface */
        border: 1px solid #54546d;  /* Kanagawa surface1 */
        border-radius: 0;
        padding: 6px 8px;
        color: #dcd7ba;
      }
      
      .hidden {
        opacity: 0;
      }
    '';
  };

  # Ghostty configuration via XDG config file
  xdg.configFile."ghostty/config".text = ''
    # Font configuration
    font-family = CaskaydiaMono Nerd Font
    font-size = 11
    
    # Shell configuration
    shell-integration = fish
    command = fish
    
    # Window configuration
    window-padding-x = 14
    window-padding-y = 14
    window-theme = dark
    
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
  '';

  # Keep Foot as backup terminal
  programs.foot = {
    enable = true;
    settings = {
      main = {
        font = "CaskaydiaMono Nerd Font:size=11";  # Updated font size
        dpi-aware = "no";
        pad = "10x10";  # Match Omarchy padding
        shell = "fish";  # Use Fish shell in foot terminal
      };
      
      # Kanagawa colors (from Omarchy)
      colors = {
        alpha = "0.98";  # Match Omarchy opacity
        
        foreground = "dcd7ba";
        background = "1f1f28";
        
        regular0 = "090618";  # black
        regular1 = "c34043";  # red
        regular2 = "76946a";  # green
        regular3 = "c0a36e";  # yellow
        regular4 = "7e9cd8";  # blue
        regular5 = "957fb8";  # magenta
        regular6 = "6a9589";  # cyan
        regular7 = "c8c093";  # white
        
        bright0 = "727169";   # bright black
        bright1 = "e82424";   # bright red
        bright2 = "98bb6c";   # bright green
        bright3 = "e6c384";   # bright yellow
        bright4 = "7fb4ca";   # bright blue
        bright5 = "938aa9";   # bright magenta
        bright6 = "7aa89f";   # bright cyan
        bright7 = "dcd7ba";   # bright white
      };
    };
  };

  # Shell configuration
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    
    shellAliases = {
      # File listing
      ls = "eza -lh --group-directories-first --icons=auto";
      lsa = "eza -lh --group-directories-first --icons=auto -a";
      lt = "eza --tree --level=2 --long --icons --git";
      lta = "eza --tree --level=2 --long --icons --git -a";
      ll = "ls -alF";
      la = "ls -A";
      l = "ls -CF";
      
      # System management
      rebuild = "sudo nixos-rebuild switch --flake .";
      update = "nix flake update";
      
      # Editor shortcuts
      v = "nvim";
      vim = "nvim";
      vi = "nvim";
      
      # Git shortcuts
      g = "git";
      ga = "git add";
      gaa = "git add --all";
      gc = "git commit";
      gcm = "git commit -m";
      gca = "git commit --amend";
      gco = "git checkout";
      gcb = "git checkout -b";
      gd = "git diff";
      gds = "git diff --staged";
      gl = "git log --oneline --graph --decorate";
      gla = "git log --oneline --graph --decorate --all";
      gp = "git push";
      gpf = "git push --force-with-lease";
      gpu = "git push -u origin HEAD";
      gpl = "git pull";
      gs = "git status";
      gss = "git status --short";
      gst = "git stash";
      gstp = "git stash pop";
      
      # Kubectl shortcuts
      k = "kubectl";
      kd = "kubectl describe";
      ke = "kubectl edit";
      kg = "kubectl get";
      kl = "kubectl logs";
      klf = "kubectl logs -f";
      ka = "kubectl apply -f";
      kdel = "kubectl delete";
      kex = "kubectl exec -it";
      
      # Common shortcuts
      c = "clear";
      h = "history";
      grep = "grep --color=auto";
      cat = "cat -v";
      mkdir = "mkdir -p";
      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";
      
      # FZF with bat preview (from nix-config)
      fz = "fzf --preview 'bat --style=numbers --color=always --line-range :500 {}'";
      
      # Use zoxide for cd
      cd = "z";
    };

    oh-my-zsh = {
      enable = true;
      plugins = [ "git" "sudo" "docker" "kubectl" ];
      theme = "robbyrussell";
    };
  };

  # Zoxide (smart cd command)
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };

  # Starship prompt (from nix-config)
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
    
    settings = {
      add_newline = false;
      command_timeout = 1200;
      scan_timeout = 10;
      format = ''
        [](bold cyan) $directory$cmd_duration$all$kubernetes$azure$docker_context$time
        $character'';
      directory = {home_symbol = " ";};
      golang = {
        #style = "bg:#79d4fd fg:#000000";
        style = "fg:#79d4fd";
        format = "[$symbol($version)]($style)";
        symbol = " ";
      };
      git_status = {
        disabled = true;
      };
      git_branch = {
        disabled = true;
        symbol = " ";
        #style = "bg:#f34c28 fg:#413932";
        style = "fg:#f34c28";
        format = "[  $symbol$branch(:$remote_branch)]($style)";
      };
      azure = {
        disabled = true;
        #style = "fg:#ffffff bg:#0078d4";
        style = "fg:#0078d4";
        format = "[  ($subscription)]($style)";
      };
      java = {
        format = "[ ($version)]($style)";
      };
      kubernetes = {
        #style = "bg:#303030 fg:#ffffff";
        style = "fg:#2e6ce6";
        #format = "\\[[󱃾 :($cluster)]($style)\\]";
        format = "[ 󱃾 ($cluster)]($style)";
        disabled = true;
      };
      docker_context = {
        disabled = false;
        #style = "fg:#1d63ed";
        format = "[ 󰡨 ($context) ]($style)";
      };
      gcloud = {disabled = true;};
      hostname = {
        ssh_only = true;
        format = "<[$hostname]($style)";
        trim_at = "-";
        style = "bold dimmed fg:white";
        disabled = true;
      };
      line_break = {disabled = true;};
      username = {
        style_user = "bold dimmed fg:blue";
        show_always = false;
        format = "user: [$user]($style)";
      };
    };
  };

  # Fish shell configuration
  programs.fish = {
    enable = true;
    
    shellAliases = {
      # File listing
      ls = "eza -lh --group-directories-first --icons=auto";
      lsa = "eza -lh --group-directories-first --icons=auto -a";
      lt = "eza --tree --level=2 --long --icons --git";
      lta = "eza --tree --level=2 --long --icons --git -a";
      ll = "ls -alF";
      la = "ls -A";  
      l = "ls -CF";
      
      # System management
      rebuild = "sudo nixos-rebuild switch --flake .";
      update = "nix flake update";
      
      # Editor shortcuts
      v = "nvim";
      vim = "nvim";
      vi = "nvim";
      
      # Git shortcuts
      g = "git";
      ga = "git add";
      gaa = "git add --all";
      gc = "git commit";
      gcm = "git commit -m";
      gca = "git commit --amend";
      gco = "git checkout";
      gcb = "git checkout -b";
      gd = "git diff";
      gds = "git diff --staged";
      gl = "git log --oneline --graph --decorate";
      gla = "git log --oneline --graph --decorate --all";
      gp = "git push";
      gpf = "git push --force-with-lease";
      gpu = "git push -u origin HEAD";
      gpl = "git pull";
      gs = "git status";
      gss = "git status --short";
      gst = "git stash";
      gstp = "git stash pop";
      
      # Kubectl shortcuts
      k = "kubectl";
      kd = "kubectl describe";
      ke = "kubectl edit";
      kg = "kubectl get";
      kl = "kubectl logs";
      klf = "kubectl logs -f";
      ka = "kubectl apply -f";
      kdel = "kubectl delete";
      kex = "kubectl exec -it";
      
      # Common shortcuts
      c = "clear";
      h = "history";
      grep = "grep --color=auto";
      cat = "cat -v";
      mkdir = "mkdir -p";
      rm = "rm -i";
      cp = "cp -i";
      mv = "mv -i";
      cd = "z";  # Use zoxide instead of cd
      
      # FZF with bat preview (from nix-config)
      fz = "fzf --preview 'bat --style=numbers --color=always --line-range :500 {}'";
    };
    
    interactiveShellInit = ''
      # Zoxide integration
      zoxide init fish | source
      
      # Any-nix-shell integration for better nix-shell experience
      ${pkgs.any-nix-shell}/bin/any-nix-shell fish --info-right | source
    '';
    
    functions = {
      fish_greeting = {
        description = "Show fastfetch and colorful fortune on startup";
        body = ''
          # Display system information first
          fastfetch
          
          # Display a colorful random fortune below
          if command -v fortune >/dev/null 2>&1 && command -v lolcat >/dev/null 2>&1
            echo
            fortune | lolcat
          else if command -v fortune >/dev/null 2>&1
            echo
            fortune
          end
        '';
      };
    };
    
    plugins = [
      {
        name = "z";
        src = pkgs.fishPlugins.z.src;
      }
      {
        name = "fzf-fish";
        src = pkgs.fishPlugins.fzf-fish.src;
      }
      {
        name = "autopair";
        src = pkgs.fishPlugins.autopair.src;
      }
    ];
  };

  # Tmux configuration
  programs.tmux = {
    enable = true;
    keyMode = "vi";
    shell = "${pkgs.fish}/bin/fish";
    plugins = with pkgs; [
      tmuxPlugins.better-mouse-mode
      tmuxPlugins.sensible
      tmuxPlugins.vim-tmux-navigator
      tmuxPlugins.resurrect
      tmuxPlugins.tmux-fzf
      tmuxPlugins.continuum
    ];
    extraConfig = ''
      set-option -g set-titles on
      set-option -g set-titles-string "tmux: #S / #(tmux-window-icons #W)"
      set -ga terminal-features ",xterm-256color:RGB"
      set-option -g default-terminal "screen-256color"
      set -s escape-time 0
      set-option -g focus-events on

      set -g base-index 1          # start indexing windows at 1 instead of 0
      set -g detach-on-destroy off # don't exit from tmux when closing a session
      set -g escape-time 0         # zero-out escape time delay
      set -g history-limit 1000000 # increase history size (from 2,000)
      set -g mouse on              # enable mouse support
      set -g renumber-windows on   # renumber all windows when any window is closed
      set -g set-clipboard on      # use system clipboard

      set -g status-interval 3     # update the status bar every 3 seconds
      set -g status-left "#[fg=blue,bold,bg=default] #S "
      set -g status-right "#(tmux-right-status)#[fg=blue] 󱑒 %a %b %d %l:%M %p"
      set -g status-justify left
      set -g status-left-length 200    # increase length (from 10)
      set -g status-right-length 200    # increase length (from 10)
      set -g status-position top       # macOS / darwin style
      #set -g status-style 'bg=#1e1e2e'
      set -g status-style 'bg=#191724'

      set -g window-status-current-format '#[fg=#e0def4,bold,bg=#26233a]#(tmux-window-icons #W)#{?window_zoomed_flag,(),}'
      set -g window-status-format '#[fg=#9893a5,bg=default]#(tmux-window-icons #W)'

      set -g window-status-last-style 'fg=white,bg=default'
      set -g message-command-style bg=default,fg=yellow
      set -g message-style bg=default,fg=yellow
      set -g mode-style bg=default,fg=yellow

      # fix SSH agent after reconnecting
      # see also ssh/rc
      # https://blog.testdouble.com/posts/2016-11-18-reconciling-tmux-and-ssh-agent-forwarding/
      set -g update-environment "DISPLAY SSH_ASKPASS SSH_AGENT_PID SSH_CONNECTION WINDOWID XAUTHORITY"

      setw -g mode-keys vi
      set -g pane-active-border-style 'fg=magenta,bg=default'
      set -g pane-border-style 'fg=brightblack,bg=default'

      set -g window-style 'fg=default,bg=default' #331d1d2e'
      set -g window-active-style 'fg=default,bg=#191724'

      bind r source-file /etc/tmux.conf
      set -g base-index 1

      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel 'xclip -in -selection clipboard'

      # vim-like pane switching
      bind -r ^ last-window
      bind -r k select-pane -U
      bind -r j select-pane -D
      bind -r h select-pane -L
      bind -r l select-pane -R

      bind-key % split-window -h -c "#{pane_current_path}"
      bind-key '"' split-window -p 30 -v -c "#{pane_current_path}"

      #bind u split-window -p 30 -c "#{pane_current_path}"
      #bind i split-window -p 50 -h -c "#{pane_current_path}"
      bind c new-window -c "#{pane_current_path}"

      bind -r D neww -c "#{pane_current_path}" "[[ -e TODO.md ]] && nvim TODO.md || nvim ~/src/notes/todo.md"

      bind -r f display-popup -E "tmux-sessionizer"
    '';
  };

  # Git configuration
  programs.git = {
    enable = true;
    userName = "aragao";
    userEmail = "your-email@example.com";  # Update with your email
  };

  # Application launcher with Kanagawa theming
  programs.wofi = {
    enable = true;
    settings = {
      width = 600;
      height = 400;
      location = "center";
      show = "drun";
      prompt = "Search...";
      filter_rate = 100;
      allow_markup = true;
      no_actions = true;
      halign = "fill";
      orientation = "vertical";
      content_halign = "fill";
      insensitive = true;
      allow_images = true;
      image_size = 48;
      gtk_dark = true;
    };
    
    style = ''
      /* Kanagawa Color Palette */
      * {
        --bg-dim: #1f1f28;
        --bg0: #16161d;
        --bg1: #1f1f28;
        --bg2: #2a2a37;
        --bg3: #363646;
        --bg4: #54546d;
        --fg: #dcd7ba;
        --fg-dim: #c8c093;
        --red: #c34043;
        --orange: #ffa066;
        --yellow: #c0a36e;
        --green: #76946a;
        --teal: #7aa89f;
        --blue: #7e9cd8;
        --purple: #957fb8;
        --gray: #727169;
      }

      window {
        margin: 0px;
        border: 2px solid var(--purple);
        border-radius: 12px;
        background-color: rgba(31, 31, 40, 0.95);
        font-family: "CaskaydiaMono Nerd Font", sans-serif;
        font-size: 14px;
        color: var(--fg);
      }

      #input {
        margin: 5px;
        border: 2px solid var(--bg3);
        border-radius: 8px;
        background-color: var(--bg1);
        color: var(--fg);
        padding: 10px;
        font-size: 16px;
      }

      #input:focus {
        border-color: var(--blue);
        box-shadow: 0 0 10px rgba(126, 156, 216, 0.3);
      }

      #inner-box {
        margin: 5px;
        border: none;
        background-color: transparent;
      }

      #outer-box {
        margin: 5px;
        border: none;
        background-color: transparent;
      }

      #scroll {
        margin: 0px;
        border: none;
        background-color: transparent;
      }

      #text {
        margin: 5px;
        border: none;
        color: var(--fg);
        font-weight: 500;
      }

      #entry {
        background-color: transparent;
        border-radius: 8px;
        margin: 2px;
        padding: 8px;
        border: none;
      }

      #entry:selected {
        background-color: var(--bg2);
        border: 1px solid var(--purple);
        color: var(--fg);
        box-shadow: 0 2px 8px rgba(149, 127, 184, 0.2);
      }

      #entry:hover {
        background-color: var(--bg1);
        border: 1px solid var(--bg4);
        color: var(--fg);
      }

      #entry:selected #text {
        color: var(--fg);
        font-weight: 600;
      }

      #entry img {
        margin-right: 10px;
        border-radius: 6px;
      }
    '';
  };

  # Brave Browser configuration
  programs.brave = {
    enable = true;
    commandLineArgs = [
      # Wayland flags disabled for X11/DWM compatibility
      # "--enable-features=UseOzonePlatform"
      # "--ozone-platform=wayland"
      "--disable-features=BraveRewards"  # Disable Brave Rewards
      "--disable-brave-ads"              # Disable Brave Ads
      "--disable-background-mode"        # Prevent running in background
    ];
    extensions = [
      # Bitwarden Password Manager
      {
        id = "nngceckbapebfimnlniiiahkandclblb";
      }
      # Vimium - vim-like navigation
      {
        id = "dbepggeogbaibhgnhhndojpepiihcmeb";
      }
      # Kanagawa theme
      {
        id = "djnghjlejbfgnbnmjfgbdaeafbiklpha";
      }
    ];
  };



  # Cursor IDE configuration (using vscode home manager module with cursor package)
  programs.vscode = {
    enable = true;
    package = pkgs.code-cursor.overrideAttrs (oldAttrs: {
      # Configure for Wayland and system decorations
      postInstall = (oldAttrs.postInstall or "") + ''
        # Create wrapper script for Wayland mode
        wrapProgram "$out/bin/cursor" \
          --add-flags "--enable-wayland-ime" \
          --add-flags "--ozone-platform-hint=auto" \
          --add-flags "--enable-features=UseOzonePlatform,WaylandWindowDecorations" \
          --add-flags "--disable-gpu-sandbox" \
          --add-flags "--disable-gpu-memory-buffer-compositor-resources" \
          --add-flags "--disable-one-copy-rasterizer" \
          --add-flags "--disable-features=UseSkiaRenderer,HardwareMediaKeyHandling,CalculateNativeWinOcclusion,BackForwardCache" \
          --add-flags "--enable-features=UseOzonePlatform,WaylandWindowDecorations,TurnOffStreamingMediaCachingOnBattery"
      '';
    });
    
    profiles.default = {
      extensions = with pkgs.vscode-extensions; [
        # Language Support
        golang.go                                 # Go
        redhat.java                               # Java Language Support
        
        # Nix Language Support
        jnoortheen.nix-ide                        # Nix language support with formatting and error report
        bbenoist.nix                              # Classic Nix syntax support
        
        # Vim Extension
        vscodevim.vim                             # Vim keybindings
        
        # General Development
        redhat.vscode-yaml                        # YAML support
        timonwong.shellcheck                      # Shell script analysis
        hashicorp.terraform                       # Terraform support
        
        # Git Integration
        eamodio.gitlens                           # Enhanced Git capabilities
        
        # Productivity  
        pkief.material-icon-theme                 # Better file icons
      ];
      
      userSettings = {
        # Theme Configuration 
        # NOTE: For Kanagawa theme, install manually from VSCode marketplace:
        # 1. Open VSCode/Cursor
        # 2. Go to Extensions (Ctrl+Shift+X)
        # 3. Search for "Kanagawa Theme" by metaphore or "Kanagawa Dragon" by qiushaoxi
        # 4. Install and set as theme via Ctrl+Shift+P -> "Color Theme"
        "workbench.colorTheme" = "Default Dark+";  # Default until Kanagawa is installed
        "workbench.iconTheme" = "material-icon-theme";
        
        # Vim Configuration
        "vim.useSystemClipboard" = true;
        "vim.useCtrlKeys" = true;
        "vim.hlsearch" = true;
        "vim.insertModeKeyBindings" = [
          {
            "before" = ["j" "j"];
            "after" = ["<Esc>"];
          }
        ];
        "vim.normalModeKeyBindingsNonRecursive" = [
          {
            "before" = ["<leader>" "w"];
            "commands" = ["workbench.action.files.save"];
          }
          {
            "before" = ["<leader>" "q"];
            "commands" = ["workbench.action.closeActiveEditor"];
          }
        ];
        "vim.leader" = "<space>";
        
        # Editor Configuration
        "editor.lineNumbers" = "relative";
        "editor.cursorSurroundingLines" = 8;
        "editor.scrollBeyondLastLine" = false;
        "editor.wordWrap" = "on";
        "editor.fontFamily" = "JetBrains Mono, 'JetBrainsMono Nerd Font', monospace";
        "editor.fontSize" = 14;
        "editor.fontLigatures" = true;
        "editor.renderWhitespace" = "boundary";
        "editor.rulers" = [80 120];
        
        # Python Configuration
        "python.defaultInterpreterPath" = "/run/current-system/sw/bin/python3";
        "python.terminal.activateEnvInCurrentTerminal" = true;
        
        # Go Configuration
        "go.toolsManagement.autoUpdate" = true;
        "go.useLanguageServer" = true;
        "go.formatTool" = "goimports";
        
        # TypeScript Configuration
        "typescript.preferences.importModuleSpecifier" = "relative";
        "typescript.updateImportsOnFileMove.enabled" = "always";
        
        # Java Configuration
        "java.home" = "/run/current-system/sw/lib/openjdk";
        "java.configuration.runtimes" = [
          {
            "name" = "JavaSE-21";
            "path" = "/run/current-system/sw/lib/openjdk";
            "default" = true;
          }
        ];
        
        # Nix Configuration
        "nix.enableLanguageServer" = true;
        "nix.serverPath" = "/run/current-system/sw/bin/nil";
        "nix.formatterPath" = "/run/current-system/sw/bin/nixfmt-rfc-style";
        "nix.serverSettings" = {
          "nil" = {
            "formatting" = {
              "command" = [ "/run/current-system/sw/bin/nixfmt-rfc-style" ];
            };
          };
        };
        
        # Terminal Configuration
        "terminal.integrated.shell.linux" = "/run/current-system/sw/bin/fish";
        "terminal.integrated.fontFamily" = "JetBrains Mono, 'JetBrainsMono Nerd Font'";
        
        # File Explorer
        "explorer.confirmDelete" = false;
        "explorer.confirmDragAndDrop" = false;
        
        # Git Configuration
        "git.enableSmartCommit" = true;
        "git.confirmSync" = false;
        "gitlens.codeLens.enabled" = false;
        
        # Wayland and Window Configuration
        "window.titleBarStyle" = "native";
        "window.menuBarVisibility" = "toggle";
        "window.autoDetectColorScheme" = true;
        
        # Miscellaneous
        "workbench.startupEditor" = "none";
        "telemetry.telemetryLevel" = "off";
        "update.mode" = "none";
        "extensions.autoCheckUpdates" = false;
      };
    };
  };

  # Additional packages for the user
  home.packages = with pkgs; [
    # Custom scripts
    (import ./screenshot.nix { inherit pkgs; })
    (import ./sway-transparency.nix { inherit pkgs; })
    
    # Tmux custom scripts
    (writeShellScriptBin "tmux-sessionizer" ''
      #!/usr/bin/env bash
      
      #set -x
      set -e
      if [[ $# -eq 1 ]]; then
        selected=$1
      else
       #find ~/projects/personal ~/projects/work -mindepth 1 -maxdepth 1 -type d|awk -F/ '{print $(NF-1)"/"$NF}'
       selected=$(find -L ~/projects/work ~/projects/personal -mindepth 1 -maxdepth 1 -type d |awk -F/ '{print $(NF-1)"/"$NF}'| fzf --preview 'bat --color=always ~/projects/{}/README.md 2>/dev/null||bat --color=always ~/projects/{}/readme.md 2>/dev/null||tree -C ~/projects/{}' )
      fi
      
      if [[ -z $selected ]]; then    
        exit 0
      fi
      
      selected=~/projects/"$selected"
      selected_name=$(basename "$selected" | tr . _)
      tmux_running=$(pgrep tmux)
      
      if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
        tmux new-session -s $selected_name -c $selected
        exit 0
      fi
      
      new_session_flag=0
      if ! tmux has-session -t=$selected_name 2> /dev/null; then
        tmux new-session -ds $selected_name -c $selected
        tmux set-environment -t $selected_name TMUX_SESSION_ROOT_DIR $selected
        new_session_flag=1
      fi
      
      tmux switch-client -t $selected_name
      if [ $new_session_flag -eq 1 ]; then
        if [[ -e ''${selected}/.tmux-setup.sh ]]; then
          cd ''${selected}
          source ''${selected}/.tmux-setup.sh ''${selected_name}
        fi
      fi
    '')
    
    (writeShellScriptBin "tmux-window-icons" ''
      #!/bin/sh
      
      declare -A icons
      
      icons["fish"]="󰈺 ";
      icons["nvim"]=" ";
      icons["vi"]=" ";
      icons["vim"]=" ";
      icons["lazydocker"]=" ";
      icons["lazygit"]=" ";
      icons["k9s"]="󱃾 ";
      icons["lf"]=" ";
      icons["python"]=" ";
      
      echo "''${icons[$1]}$1"
    '')
    
    (writeShellScriptBin "tmux-right-status" ''
      #!/bin/sh
      # set -x
      function get_k8s_output(){
        local output
        if [ -f ~/.kube/config ]; then
          output="$(grep 'current-context:' ~/.kube/config | awk '{print $2}')"
          if [ -n "$output" ]; then
            output="#[fg=#2e6ce6,bold,bg=default]󱃾 $output"
          fi
        fi
        echo $output
      }
      
      function get_az_output(){
        local output
        if [ -f ~/.config/azure/azureProfile.json ]; then
          output=$(jq -r '.subscriptions[] | select(.isDefault==true) | .name' ~/.config/azure/azureProfile.json)
          if [ -n "$output" ]; then
            output="#[fg=#0078d4,bold,bg=default] $output"
          fi
        fi
        echo $output
      }
      
      function get_project_output(){
        local output
        local project_dir
        project_dir="$(tmux show-environment TMUX_SESSION_ROOT_DIR|cut -d'=' -f2|awk -F/ '{print $(NF-1)"/"$NF}')"
        if [ -n "$project_dir" ]; then
          output="#[fg=#ebbcba] $project_dir"
        else
          output="#[fg=#ebbcba] $(pwd)"
        fi
        echo $output
      }
      
      function get_git_output(){
        echo $(tmux-git-status)
      }
      
      echo $(get_git_output) $(get_k8s_output) $(get_az_output) $(get_project_output)
    '')
    
    (writeShellScriptBin "tmux-git-status" ''
      #!/bin/bash
      # Function to get the current Git branch
      get_git_branch() {
      	# Use git symbolic-ref or git rev-parse to retrieve the branch name
      	local branch_name=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
      	echo "$branch_name"
      }
      
      # Function to get the Git status
      get_git_status() {
      	local status=$(git status --porcelain 2>/dev/null)
      	local output=""
      
      	if [[ -n $status ]]; then
      		# Check for modified files
      		if echo "$status" | grep -q '^.M\|M.$'; then
      			output+="*"
      		fi
      		# Check for added files
      		if echo "$status" | grep -q '^A'; then
      			output+="+"
      		fi
      		# Check for deleted files
      		if echo "$status" | grep -q '^.D\|D.$'; then
      			output+="-"
      		fi
      		# Check for renamed files
      		if echo "$status" | grep -q '^.R\|R.$'; then
      			output+=">"
      		fi
      		# Check for untracked files
      		if echo "$status" | grep -q '^??'; then
      			output+="?"
      		fi
      	fi
      
      	echo "$output"
      }
      
      # Main script execution
      branch=$(get_git_branch)
      if [[ -n $branch ]]; then
      	git_status=$(get_git_status)
      	echo "#[fg=#f34c28]  $branch#[fg=#eb6f92][$git_status]"
      else
      	echo ""
      fi
    '')
    # GUI Applications
    qutebrowser
    xfce.thunar
    xfce.tumbler  # Thumbnail service for Thunar
    xfce.xfconf  # Configuration system for Thunar
    ffmpegthumbnailer  # Video thumbnails
    poppler_utils  # PDF thumbnails
    pavucontrol
    pamixer  # Volume control for waybar
    ghostty

    # Development tools
    
    # Programming languages and runtimes
    python3
    go
    nodejs_22
    yarn
    openjdk21
    maven
    gradle
    
    # Python development tools
    uv    # Fast Python package installer and project manager
    ruff  # Python linter/formatter
    
    # Go development tools
    delve  # Go debugger
    
    # JavaScript/TypeScript development tools
    typescript
    
    # Cloud development tools
    docker
    docker-compose
    kubectl
    awscli2
    terraform
    
    # Version control and utilities
    git
    gh  # GitHub CLI
    jq  # JSON processor
    yq  # YAML processor
    curl
    wget
    
    # Build tools for Neovim plugins
    gcc
    gnumake
    pkg-config
    
    # Lua ecosystem for Neovim plugins
    lua
    luarocks
    
    # Additional dependencies for building Lua rocks
    unzip  # Many rocks need this for extraction
    cmake  # Some native extensions need cmake
    
    # Tree-sitter for nvim-treesitter
    tree-sitter  # Parser generator for treesitter grammars
    
    # LSP servers (needed for Mason to work properly)
    nil  # Nix LSP
    nixfmt-rfc-style  # Nix formatter
    bash-language-server
    marksman  # Markdown LSP
    pyright  # Python LSP (faster and more reliable than pylsp)
    gopls  # Go LSP  
    nodePackages.typescript-language-server
    nodePackages.vscode-langservers-extracted  # HTML/CSS/JSON/ESLint LSPs
    jdt-language-server  # Java LSP
    
    # Fish shell and plugins
    fish
    fishPlugins.z
    fishPlugins.fzf-fish
    fishPlugins.autopair
    
    # System utilities
    neofetch
    fastfetch  # Modern system info tool
    fortune    # Random quotes and sayings
    lolcat     # Colorful text output
    any-nix-shell  # Better nix-shell experience
    fzf  # Fuzzy finder
    hyprpaper
    swayosd  # On-screen display for volume/brightness
    playerctl  # Media player control
    eza  # Modern replacement for ls (used in Omarchy aliases)
    libnotify  # For desktop notifications (notify-send)
    mako  # Notification daemon (Wayland)
    dunst  # Notification daemon (X11/Wayland)
    btop  # Modern system monitor
    
    # Input method framework (Omarchy style)
    fcitx5
    fcitx5-gtk
    libsForQt5.fcitx5-qt
    
    # Media
    mpv
    
    # Audio tools
    pulseaudio  # Provides pactl and other PulseAudio utilities for PipeWire compatibility
    
    # Status bars
    polybar  # Customizable status bar for X11
    
    # Screenshots (Omarchy style)
    hyprshot  # Screenshot tool for Hyprland
    satty     # Screenshot editor/annotator
    slurp     # Screen area selection tool
    wl-clipboard  # Wayland clipboard utilities (includes wl-copy)
    
    # Sway specific tools
    swaybg    # Background utility for sway
    wlogout   # Logout menu for Wayland
    imagemagick  # For wallpaper generation
    
    # Fonts  
    # jetbrains-mono already included above
    jetbrains-mono  # JetBrains Mono 
    liberation_ttf  # Liberation Sans for UI
    noto-fonts-emoji
    font-awesome  # For additional icons and symbols
    noto-fonts-color-emoji  # Color emoji support
  # Install all Nerd Fonts
  ] ++ (builtins.filter pkgs.lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts));

  # Cursor configuration (system-wide)
  home.pointerCursor = {
    package = pkgs.bibata-cursors;
    name = "Bibata-Modern-Classic";
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  # GTK theme configuration
  gtk = {
    enable = true;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name = "Yaru-blue";
      package = pkgs.yaru-theme;
    };
    cursorTheme = {
      name = "Bibata-Modern-Classic";
      package = pkgs.bibata-cursors;
      size = 24;
    };
    gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = 1;
    };
    gtk4.extraConfig = {
      gtk-application-prefer-dark-theme = 1;
    };
  };

  # Qt theme configuration (for Qt apps to match GTK dark theme)
  qt = {
    enable = true;
    platformTheme.name = "adwaita";
    style.name = "adwaita-dark";
  };

  # dconf settings for GNOME applications
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      gtk-theme = "Adwaita-dark";
      icon-theme = "Yaru-blue";
      cursor-theme = "Bibata-Modern-Classic";
      color-scheme = "prefer-dark";
    };
    
    "org/gtk/settings/file-chooser" = {
      show-type-column = true;
      sidebar-width = 152;
      date-format = "with-time";
      location-mode = "path-bar";
      show-hidden = true;
      show-size-column = true;
      sort-column = "modified";
      sort-directories-first = true;
      sort-order = "ascending";
      type-format = "category";
    };
  };

  # Font configuration
  fonts.fontconfig.enable = true;

  # Enable XDG user directories with custom lowercase names (no Desktop, Templates, or Public)
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
    desktop = null;  # Disable Desktop folder
    templates = null;  # Disable Templates folder
    publicShare = null;  # Disable Public folder
    documents = "${config.home.homeDirectory}/documents";
    download = "${config.home.homeDirectory}/downloads";
    music = "${config.home.homeDirectory}/music";
    pictures = "${config.home.homeDirectory}/pictures";
    videos = "${config.home.homeDirectory}/videos";
    
    # Custom project directories
    extraConfig = {
      XDG_PROJECTS_DIR = "${config.home.homeDirectory}/projects";
      XDG_WORK_DIR = "${config.home.homeDirectory}/projects/work";
      XDG_PERSONAL_DIR = "${config.home.homeDirectory}/projects/personal";
    };
  };

   

  # Systemd services - auto-rebuild enabled
  systemd.user.services.nixos-auto-rebuild = {
    Unit = {
      Description = "NixOS Auto-Rebuild Monitor";
      After = [ "graphical-session.target" ];
    };
    
    Service = {
      Type = "exec";
      ExecStart = "/home/aragao/projects/personal/nix/auto-rebuild.sh";
      WorkingDirectory = "/home/aragao/projects/personal/nix";
      Restart = "on-failure";
      RestartSec = "10";
      Environment = [
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/home/aragao/.nix-profile/bin:/etc/profiles/per-user/aragao/bin:/usr/bin:/bin"
        "DISPLAY=:0"
        "WAYLAND_DISPLAY=wayland-1"
        "HOME=/home/aragao"
      ];
    };
    
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Override dunst service to only run in X11 sessions
  systemd.user.services.dunst = {
    Unit = {
      Description = lib.mkForce "Dunst notification daemon (X11 only)";
      After = [ "graphical-session.target" ];
      ConditionPathExists = lib.mkForce "/tmp/.X11-unix/X0";  # Only start if X11 is running
    };
    
    Service = {
      Type = lib.mkForce "dbus";
      BusName = lib.mkForce "org.freedesktop.Notifications";
      ExecStart = lib.mkForce "${pkgs.dunst}/bin/dunst";
      Restart = lib.mkForce "always";
      Environment = lib.mkForce ["DISPLAY=:0"];
    };
    
    Install = {
      WantedBy = lib.mkForce [ "default.target" ];
    };
  };

  # Picom compositor service for X11 only
  systemd.user.services.picom = {
    Unit = {
      Description = "Picom X11 compositor";
      After = [ "graphical-session.target" ];
      ConditionPathExists = "/tmp/.X11-unix/X0";  # Only start if X11 is running
    };
    
    Service = {
      Type = "forking";
      ExecStart = "${pkgs.picom}/bin/picom --config /etc/xdg/picom.conf --daemon";
      Restart = "always";
      RestartSec = "3";
      Environment = ["DISPLAY=:0"];
    };
    
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Wallpaper service for X11 only
  systemd.user.services.wallpaper = {
    Unit = {
      Description = "Set X11 wallpaper with feh";
      After = [ "graphical-session.target" "picom.service" ];
      ConditionPathExists = "/tmp/.X11-unix/X0";  # Only start if X11 is running
    };
    
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c 'if [ -f \"$HOME/.local/share/wallpapers/1-kanagawa.jpg\" ]; then ${pkgs.feh}/bin/feh --bg-fill \"$HOME/.local/share/wallpapers/1-kanagawa.jpg\"; else ${pkgs.xorg.xsetroot}/bin/xsetroot -solid \"#1f1f28\"; fi'";
      Environment = ["DISPLAY=:0"];
    };
    
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
  
  # Custom Polybar service using polybar-dwm-module
  systemd.user.services.polybar-dwm = {
    Unit = {
      Description = "Polybar status bar with DWM integration (X11 only)";
      After = [ "graphical-session.target" "wallpaper.service" ];
      ConditionPathExists = "/tmp/.X11-unix/X0";  # Only start if X11 is running
    };
    
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.writeShellScript "polybar-dwm-start" ''
        # Only start in X11 sessions
        if [ -z "$DISPLAY" ]; then
          echo "Not running in X11, skipping polybar"
          exit 0
        fi
        
        # Start polybar with dwm module using nix store config
        ${pkgs.polybar-dwm-module}/bin/polybar --config=${pkgs.writeText "polybar-config.ini" ''
[bar/main]
monitor=
width=100%
height=30
radius=0
fixed-center=true

background=#1f1f28
foreground=#dcd7ba

line-size=2
line-color=#7e9cd8

border-size=0
border-color=#54546d

padding-left=2
padding-right=2

module-margin-left=1
module-margin-right=1

font-0=CaskaydiaMono Nerd Font:style=Regular:size=10;2
font-1=CaskaydiaMono Nerd Font:style=Regular:size=12;3
font-2=Noto Color Emoji:scale=10:style=Regular;2

modules-left=dwm
modules-center=date
modules-right=alsa memory cpu tray

cursor-click=pointer
cursor-scroll=ns-resize

enable-ipc=true
override-redirect=false

[module/dwm]
type=internal/dwm
format=<label-tags> <label-layout> <label-floating> <label-title>

label-focused=%name%
label-focused-background=#7e9cd8
label-focused-foreground=#1f1f28
label-focused-padding=1

label-unfocused=%name%
label-unfocused-padding=1
label-unfocused-foreground=#dcd7ba

label-visible=%name%
label-visible-background=#2a2a37
label-visible-foreground=#dcd7ba
label-visible-padding=1

label-urgent=%name%
label-urgent-background=#ff5d62
label-urgent-foreground=#1f1f28
label-urgent-padding=1

label-empty=%name%
label-empty-foreground=#54546d
label-empty-padding=1

label-layout=%symbol%
label-layout-padding=1
label-layout-foreground=#7e9cd8

label-floating=F
label-floating-foreground=#e6c384

label-title=%title%
label-title-padding=1
label-title-foreground=#dcd7ba
label-title-maxlen=30

socket-path=/tmp/dwm.sock
enable-tags-click=true
enable-layout-click=true

[module/date]
type=internal/date
interval=5

date=
date-alt= %Y-%m-%d

time=%H:%M
time-alt=%H:%M:%S

format-prefix= 
format-prefix-foreground=#7e9cd8
format-prefix-font=2
format-foreground=#dcd7ba

label=%date% %time%

[module/alsa]
type=internal/alsa

format-volume=<label-volume> <bar-volume>
label-volume= %percentage%%
label-volume-foreground=#dcd7ba
label-volume-font=2

label-muted= muted
label-muted-foreground=#54546d
label-muted-font=2

bar-volume-width=8
bar-volume-foreground-0=#7e9cd8
bar-volume-foreground-1=#7e9cd8
bar-volume-foreground-2=#7e9cd8
bar-volume-foreground-3=#7e9cd8
bar-volume-foreground-4=#e6c384
bar-volume-foreground-5=#e6c384
bar-volume-foreground-6=#ff5d62
bar-volume-gradient=false
bar-volume-indicator=▐
bar-volume-indicator-font=1
bar-volume-fill=▌
bar-volume-fill-font=1
bar-volume-empty=▌
bar-volume-empty-font=1
bar-volume-empty-foreground=#54546d

[module/memory]
type=internal/memory
interval=2
format-prefix= 
format-prefix-foreground=#7e9cd8
format-prefix-font=2
label=%percentage_used%%

[module/cpu]
type=internal/cpu
interval=2
format-prefix= 
format-prefix-foreground=#7e9cd8
format-prefix-font=2
label=%percentage:2%%

[module/tray]
type=internal/tray
format-margin=8
tray-spacing=8
tray-background=#1f1f28
        ''} main 2>&1 >> /tmp/polybar-dwm.log
      ''}";
      Environment = [ "DISPLAY=:0" "PATH=${config.home.profileDirectory}/bin" ];
      Restart = "on-failure";
      RestartSec = "3s";
    };
    
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Set default browser to brave
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = "brave-browser.desktop";
      "x-scheme-handler/http" = "brave-browser.desktop";
      "x-scheme-handler/https" = "brave-browser.desktop";
      "x-scheme-handler/about" = "brave-browser.desktop";
      "x-scheme-handler/unknown" = "brave-browser.desktop";
    };
  };

  # UWSM configuration for Hyprland
  xdg.desktopEntries.default = {
    name = "Hyprland";
    comment = "Hyprland compositor";
    exec = "Hyprland";
    categories = [ "System" ];
    noDisplay = false;
  };

  # UWSM Hyprland service
  xdg.configFile."uwsm/env".text = ''
    export XDG_CURRENT_DESKTOP=Hyprland
    export XDG_SESSION_TYPE=wayland
    export XDG_SESSION_DESKTOP=Hyprland
  '';

  # Create wallpaper directory and provide default wallpaper
  home.file.".local/share/wallpapers/.keep".text = "";
  
  # Create a simple gradient wallpaper if Kanagawa wallpaper isn't available
  home.activation.createWallpaper = lib.hm.dag.entryAfter ["writeBoundary"] ''
    WALLPAPER_DIR="${config.home.homeDirectory}/.local/share/wallpapers"
    WALLPAPER_FILE="$WALLPAPER_DIR/1-kanagawa.jpg"
    
    # Create wallpaper directory
    mkdir -p "$WALLPAPER_DIR"
    
    # If wallpaper doesn't exist, create a simple solid color one using ImageMagick (if available)
    if [[ ! -f "$WALLPAPER_FILE" ]]; then
      echo "Creating default Kanagawa-themed wallpaper..."
      if command -v ${pkgs.imagemagick}/bin/convert >/dev/null 2>&1; then
        # Create a simple gradient wallpaper with Kanagawa colors
        $DRY_RUN_CMD ${pkgs.imagemagick}/bin/convert -size 1920x1080 \
          gradient:"#1f1f28-#2a2a37" \
          "$WALLPAPER_FILE"
        echo "Created default wallpaper at $WALLPAPER_FILE"
      else
        echo "ImageMagick not available. Please manually add a wallpaper at $WALLPAPER_FILE"
        # Create a placeholder file to prevent errors
        $DRY_RUN_CMD touch "$WALLPAPER_FILE"
      fi
    fi
  '';
  
  # hyprpaper configuration
  xdg.configFile."hypr/hyprpaper.conf".text = ''
    preload = ${config.home.homeDirectory}/.local/share/wallpapers/1-kanagawa.jpg
    wallpaper = ,${config.home.homeDirectory}/.local/share/wallpapers/1-kanagawa.jpg
    splash = false
  '';

  # fcitx5 configuration (Omarchy style)
  xdg.configFile."fcitx5/conf/xcb.conf".text = ''
    Allow Overriding System XKB Settings=False
  '';

  # SwayOSD configuration (Omarchy style with Kanagawa theme)
  xdg.configFile."swayosd/config.toml".text = ''
    [server]
    show_percentage = true
    max_volume = 100
    style = "./style.css"
  '';

  xdg.configFile."swayosd/style.css".text = ''
    /* Kanagawa colors for SwayOSD */
    @define-color background-color #1f1f28;
    @define-color border-color #dcd7ba;
    @define-color label #dcd7ba;
    @define-color image #dcd7ba;
    @define-color progress #dcd7ba;

    window {
      border-radius: 0;
      opacity: 0.97;
      border: 2px solid @border-color;
      background-color: @background-color;
    }

    label {
      font-family: 'CaskaydiaMono Nerd Font';
      font-size: 11pt;
      color: @label;
    }

    image {
      color: @image;
    }

    progressbar {
      border-radius: 0;
    }

    progress {
      background-color: @progress;
    }
  '';

  # wlogout configuration (for sway)
  xdg.configFile."wlogout/layout".text = ''
    {
        "label" : "lock",
        "action" : "swaylock -f -c 1f1f28",
        "text" : "Lock",
        "keybind" : "l"
    }
    {
        "label" : "logout",
        "action" : "swaymsg exit",
        "text" : "Logout",
        "keybind" : "e"
    }
    {
        "label" : "shutdown",
        "action" : "systemctl poweroff",
        "text" : "Shutdown",
        "keybind" : "s"
    }
    {
        "label" : "suspend",
        "action" : "systemctl suspend",
        "text" : "Suspend",
        "keybind" : "u"
    }
    {
        "label" : "reboot",
        "action" : "systemctl reboot",
        "text" : "Reboot",
        "keybind" : "r"
    }
  '';

  xdg.configFile."wlogout/style.css".text = ''
    * {
      background-color: #1f1f28;
      color: #dcd7ba;
      font-family: CaskaydiaMono Nerd Font;
      font-size: 14px;
    }

    window {
      background-color: rgba(31, 31, 40, 0.9);
    }

    button {
      background-color: #54546d;
      border: 2px solid #dcd7ba;
      border-radius: 10px;
      color: #dcd7ba;
      margin: 10px;
      min-width: 100px;
      min-height: 100px;
    }

    button:hover {
      background-color: #dcd7ba;
      color: #1f1f28;
    }

    button:focus {
      background-color: #c34043;
      color: #dcd7ba;
    }
  '';

  # GTK bookmarks for Thunar sidebar
  xdg.configFile."gtk-3.0/bookmarks".text = ''
    file://${config.home.homeDirectory}/projects projects
    file://${config.home.homeDirectory}/projects/work work
    file://${config.home.homeDirectory}/projects/personal personal
    file://${config.home.homeDirectory}/documents documents
    file://${config.home.homeDirectory}/downloads downloads
  '';

  # Thunar file manager configuration via home-manager activation  
  home.activation.configureThunar = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # Create project directories if they don't exist
    mkdir -p "${config.home.homeDirectory}/projects/work"
    mkdir -p "${config.home.homeDirectory}/projects/personal"
    echo "Created project directories"
    
    # Configure Thunar via xfconf-query during home-manager activation
    if command -v xfconf-query >/dev/null 2>&1; then
      echo "Configuring Thunar via xfconf..."
      
      # Set default view to details (list view)  
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /default-view -s "ThunarDetailsView" --create --type string
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-view -s "ThunarDetailsView" --create --type string
      
      # Enable working directory for terminal commands
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /misc-exec-shell-command-working-directory -s true --create --type bool
      
      # Enable thumbnails
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /misc-show-thumbnails -s true --create --type bool
      
      # Show toolbar and statusbar
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-toolbar-visible -s true --create --type bool
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-statusbar-visible -s true --create --type bool
      
      # Set folders first in sorting
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /misc-folders-first -s true --create --type bool
      
      # Set reasonable window size
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-window-width -s 900 --create --type int
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-window-height -s 600 --create --type int
      
      # Column widths for details view (name, size, type, modified)
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-details-view-column-widths -s "250,100,100,150" --create --type string
      
      # Show side panel with shortcuts
      $DRY_RUN_CMD ${pkgs.xfce.xfconf}/bin/xfconf-query -c thunar -p /last-side-pane -s "ThunarShortcutsPane" --create --type string
      
      echo "Thunar configuration completed"
    else
      echo "xfconf-query not available, skipping Thunar configuration"
    fi
  '';

  # Thunar custom actions (set foot as terminal)
  xdg.configFile."Thunar/uca.xml".text = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <actions>
    <action>
      <icon>utilities-terminal</icon>
      <name>Open Terminal Here</name>
      <unique-id>1409659827532001-1</unique-id>
      <command>foot --working-directory=%f</command>
      <description>Open foot terminal in the current directory</description>
      <patterns>*</patterns>
      <startup-notify/>
      <directories/>
    </action>
    </actions>
  '';

  # Fastfetch configuration (Omarchy style adapted for NixOS)
  xdg.configFile."fastfetch/config.jsonc".text = ''
    {
      "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
      "logo": {
        "type": "builtin",
        "source": "nixos",
        "color": { "1": "blue" },
        "padding": {
          "top": 2,
          "right": 6,
          "left": 2
        }
      },
      "modules": [
        "break",
        {
          "type": "custom",
          "format": "\u001b[90m┌──────────────────────Hardware──────────────────────┐"
        },
        {
          "type": "host",
          "key": "󰟀 PC",
          "keyColor": "green"
        },
        {
          "type": "cpu",
          "key": "│ ├󰍛",
          "showPeCoreCount": true,
          "keyColor": "green"
        },
        {
          "type": "gpu",
          "key": "│ ├󰢮",
          "detectionMethod": "pci",
          "keyColor": "green"
        },
        {
          "type": "display",
          "key": "│ ├󰍹",
          "keyColor": "green"
        },
        {
          "type": "disk",
          "key": "│ ├󰋊",
          "keyColor": "green"
        },
        {
          "type": "memory",
          "key": "│ ├󰑭",
          "keyColor": "green"
        },
        {
          "type": "swap",
          "key": "└ └󰾵",
          "keyColor": "green"
        },
        {
          "type": "custom",
          "format": "\u001b[90m└────────────────────────────────────────────────────┘"
        },
        "break",
        {
          "type": "custom",
          "format": "\u001b[90m┌──────────────────────Software──────────────────────┐"
        },
        {
          "type": "os",
          "key": "󰣇 OS",
          "keyColor": "blue"
        },
        {
          "type": "kernel",
          "key": "│ ├󰌽",
          "keyColor": "blue"
        },
        {
          "type": "wm",
          "key": "│ ├󰨇",
          "keyColor": "blue"
        },
        {
          "type": "de",
          "key": "󰧨 DE",
          "keyColor": "blue"
        },
        {
          "type": "terminal",
          "key": "│ ├󰆍",
          "keyColor": "blue"
        },
        {
          "type": "packages",
          "key": "│ ├󰏖",
          "keyColor": "blue"
        },
        {
          "type": "wmtheme",
          "key": "│ ├󰉼",
          "keyColor": "blue"
        },
        {
          "type": "custom",
          "key": "│ ├󰸌",
          "keyColor": "blue",
          "format": "Kanagawa 󰮯"
        },
        {
          "type": "terminalfont",
          "key": "└ └󰛖",
          "keyColor": "blue"
        },
        {
          "type": "custom",
          "format": "\u001b[90m└────────────────────────────────────────────────────┘"
        },
        "break",
        {
          "type": "custom",
          "format": "\u001b[90m┌────────────────────Uptime / Age────────────────────┐"
        },
        {
          "type": "command",
          "key": "  OS Age ",
          "keyColor": "magenta",
          "text": "birth_install=$(stat -c %W /); current=$(date +%s); time_progression=$((current - birth_install)); days_difference=$((time_progression / 86400)); echo $days_difference days"
        },
        {
          "type": "uptime",
          "key": "  Uptime ",
          "keyColor": "magenta"
        },
        {
          "type": "custom",
          "format": "\u001b[90m└────────────────────────────────────────────────────┘"
        },
        "break"
      ]
    }
  '';

  # Xresources configuration with Kanagawa colors and centralized DPI
  xresources = {
    properties = {
      "*.foreground" = "#dcd7ba";
      "*.background" = "#1f1f28";
      "*.cursorColor" = "#dcd7ba";

      "*.color0" = "#16161d";
      "*.color8" = "#727169";

      "*.color1" = "#c34043";
      "*.color9" = "#e82424";

      "*.color2" = "#76946a";
      "*.color10" = "#98bb6c";

      "*.color3" = "#c0a36e";
      "*.color11" = "#e6c384";

      "*.color4" = "#7e9cd8";
      "*.color12" = "#7fb4ca";

      "*.color5" = "#957fb8";
      "*.color13" = "#938aa9";

      "*.color6" = "#6a9589";
      "*.color14" = "#7aa89f";

      "*.color7" = "#c8c093";
      "*.color15" = "#dcd7ba";

      "XTerm*font" = "xft:JetbrainsMono Nerd Font:size=10";
      "XTerm*saveLines" = "100000";
      "XTerm*scrollBar" = "false";
      "XTerm*termName" = "xterm-256color";
      "XTerm*backarrowKey" = "false";
      "XTerm*selectToClipboard" = "true";
      "Xterm.ttyModes" = "erase ^?";
      "Xterm*cursorTheme" = "Bibata-Modern-Classic";
      "XTerm*pointerShape" = "left_ptr";
      "Xft.dpi" = 144;
      "Cairo.dpi" = 144;
      "*.dpi" = 144;
    };
  };
}
