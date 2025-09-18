{
  config,
  pkgs,
  lib,
  inputs,
  lockScreen ? false,
  ...
}:

{
  # Niri configuration with Hyprland-like keybindings
  xdg.configFile."niri/config.kdl".text = ''
    workspace "1" 
    workspace "2" 
    workspace "3"
    workspace "4"

    // Monitor/Output configuration (matching Hyprland 2.0 scale)
    output "Virtual-1" {
        // Default configuration for all outputs
        scale 2.0 
    }


    output "DP-1" {
        // Default configuration for all outputs
        mode "3840x2160@144.000"
        scale 1.75 
    }

    // Define workspaces with numbers

    // Spawn programs on startup (others managed by systemd user services)
    spawn-at-startup "prlcc"


    // Environment variables
    environment {
        QT_QPA_PLATFORM "wayland"
        QT_WAYLAND_DISABLE_WINDOWDECORATION "1"
        GDK_BACKEND "wayland,x11"
        NIXOS_OZONE_WL "1"
        MOZ_ENABLE_WAYLAND "1"
        XCURSOR_SIZE "24"
    }

    cursor {
        xcursor-size 24
        hide-when-typing
        hide-after-inactive-ms 1000
    }

    // Input configuration (similar to Hyprland input)
    input {
        focus-follows-mouse
        keyboard {
            xkb {
                layout "us"
                variant "mac"
                options "compose:caps"
            }
            repeat-delay 600
            repeat-rate 40
        }
        
        mouse {
            // natural-scroll
            scroll-factor 0.4
        }
    }

    // Layout configuration (similar to Hyprland dwindle)
    layout {
        gaps 10
        
        default-column-width { proportion 0.5; }
        
        focus-ring {
            width 4
            active-color "#dcd7ba"  // Kanagawa foreground
            inactive-color "#595959"
        }
        
        border {
            off  // Using focus ring instead
        }
        
        // Disable struts (reserved spaces) for cleaner look
        struts {
            left 0
            right 0
            top 0
            bottom 0
        }
        // Tab indicator at the top of windows within columns
        tab-indicator {
            position "top"
            place-within-column
            width 8
            gap 8
            length total-proportion=1.0
        }
    }

    // Window rules (similar to Hyprland windowrule)
    // Global rounded corners for all windows
    window-rule {
        geometry-corner-radius 12
        clip-to-geometry true
    }

    // Transparency: focused slightly more transparent than unfocused
    window-rule {
        match is-active=true
        opacity 0.97
    }

    window-rule {
        match is-active=false
        opacity 0.92
    }

    window-rule {
        match app-id="org.pulseaudio.pavucontrol"
        open-floating true
        default-column-width { fixed 800; }
        open-on-output "current"
    }

    window-rule {
        match app-id="Bitwarden"
        open-floating true
        default-column-width { fixed 800; }
        open-on-output "current"
    }

    window-rule {
        match title="Extension: (Bitwarden Password Manager) - Bitwarden — Mozilla Firefox"
        open-floating true
        open-on-output "current"
    }

    window-rule {
        match title="Parallels Shared Clipboard"
        open-floating true
        opacity 0.0
        default-column-width { fixed 1; }
    }

    window-rule {
        match title="MainPicker"
        open-floating true
        default-column-width { fixed 621; }
        open-on-output "current"
    }

    // Prefer no server-side decorations (clean look like Hyprland)
    prefer-no-csd

    // Screenshot path
    screenshot-path "~/pictures/screenshots/screenshot-%Y-%m-%d_%H-%M-%S.png"

    // Animations (simplified like Hyprland config)
    animations {
        slowdown 1.0
        
        window-open {
            duration-ms 150
            curve "ease-out-quad"
        }
        window-close {
            duration-ms 100
            curve "ease-out-quad"
        }
        workspace-switch {
            duration-ms 200
            curve "ease-out-quad"
        }
    }

    hotkey-overlay{
       skip-at-startup
       hide-not-bound 
    }

    // Key bindings (matching Hyprland as closely as possible)
    binds {
        // Applications (using foot as default terminal)
        Mod+Return { spawn "footclient"; }
        Mod+F { spawn "thunar"; }
        Mod+B { spawn "qutebrowser"; }
        Mod+M { spawn "spotify"; }
        Mod+N { spawn "notes"; }
        Mod+G { spawn "brave" "--app=https://web.whatsapp.com"; }
        Mod+T { spawn "firefox" "-P" "app" "--new-window" "https://teams.microsoft.com"; }
        Mod+Backslash { spawn "bitwarden"; }
        Mod+A { spawn "brave" "--app=https://grok.com"; }
        Mod+X { spawn "brave" "--app=https://x.com"; }
        Mod+O { spawn "web-apps-launcher"; }
        Mod+S { spawn "footclient" "btop"; }

        // Menu and launcher
        Mod+Space { spawn "wofi" "--show" "drun"; }
        Mod+Alt+Space { spawn "footclient"; }
        Mod+Escape { spawn "wlogout"; }

        // Window management
        Mod+W { close-window; }
        Mod+Shift+Q { quit; }
        Shift+F9 { fullscreen-window; }
        Shift+F10 { maximize-column; }
        Mod+V { toggle-window-floating; }

        // Focus movement (arrow keys and vim keys)
        Mod+Left { focus-column-left; }
        Mod+Right { focus-column-right; }
        Mod+Up { focus-window-up; }
        Mod+Down { focus-window-down; }
        Mod+h { focus-column-left; }
        Mod+l { focus-column-right; }
        Mod+k { focus-window-up; }
        Mod+j { focus-window-down; }

        Mod+c {toggle-column-tabbed-display; }

        // Window movement (vim keys and arrows)
        Mod+Shift+Left { move-column-left; }
        Mod+Shift+Right { move-column-right; }
        Mod+Shift+Up { move-window-up; }
        Mod+Shift+Down { move-window-down; }
        Mod+Shift+H { move-column-left; }
        Mod+Shift+L { move-column-right; }
        Mod+Shift+K { move-window-up; }
        Mod+Shift+J { move-window-down; }

        // Consume or expel window (bracket keys)
        Mod+BracketLeft { consume-or-expel-window-left; }
        Mod+BracketRight { consume-or-expel-window-right; }

        // Workspace switching (using number keys)
        Mod+1 { focus-workspace 1; }
        Mod+2 { focus-workspace 2; }
        Mod+3 { focus-workspace 3; }
        Mod+4 { focus-workspace 4; }
        Mod+5 { focus-workspace 5; }
        Mod+6 { focus-workspace 6; }
        Mod+7 { focus-workspace 7; }
        Mod+8 { focus-workspace 8; }
        Mod+9 { focus-workspace 9; }
        Mod+0 { focus-workspace 10; }

        // Move window to workspace


        Mod+Shift+1 { move-column-to-workspace 1; }
        Mod+Shift+2 { move-column-to-workspace 2; }
        Mod+Shift+3 { move-column-to-workspace 3; }
        Mod+Shift+4 { move-column-to-workspace 4; }
        Mod+Shift+5 { move-column-to-workspace 5; }
        Mod+Shift+6 { move-column-to-workspace 6; }
        Mod+Shift+7 { move-column-to-workspace 7; }
        Mod+Shift+8 { move-column-to-workspace 8; }
        Mod+Shift+9 { move-column-to-workspace 9; }
        Mod+Shift+0 { move-column-to-workspace 10; }

        // Tab between workspaces  
        Mod+Tab { focus-workspace-down; }
        Mod+Shift+Tab { focus-workspace-up; }

        // Column width adjustment (similar to Hyprland resize)
        Mod+Minus { set-column-width "-100"; }
        Mod+Equal { set-column-width "+100"; }
        Mod+Shift+Minus { set-window-height "-100"; }
        Mod+Shift+Equal { set-window-height "+100"; }

        // Screenshots (Hyprland-style via script)
        Mod+Shift+S { spawn "screenshot"; }
        Mod+Shift+F { spawn "screenshot" "output"; }
        
        ${lib.optionalString lockScreen ''
          // Lock screen (only on desktop machines)  
          Mod+Ctrl+L { spawn "swaylock" "-f"; }
        ''}

        // Notification control
        Mod+Semicolon { spawn "makoctl" "restore"; }

        // Waybar toggle
        Mod+Y { spawn "sh" "-c" "pkill waybar || waybar -c ~/.config/waybar/niri-config.json -s ~/.config/waybar/style.css"; }

        // Media keys (using SwayOSD)
        XF86AudioRaiseVolume { spawn "swayosd-client" "--output-volume" "raise"; }
        XF86AudioLowerVolume { spawn "swayosd-client" "--output-volume" "lower"; }
        XF86AudioMute { spawn "swayosd-client" "--output-volume" "mute-toggle"; }
        XF86AudioMicMute { spawn "pamixer" "--default-source" "-t"; }
        XF86MonBrightnessUp { spawn "swayosd-client" "--brightness" "raise"; }
        XF86MonBrightnessDown { spawn "swayosd-client" "--brightness" "lower"; }

        // Precise media adjustments with Alt
        Alt+XF86AudioRaiseVolume { spawn "pamixer" "-i" "1"; }
        Alt+XF86AudioLowerVolume { spawn "pamixer" "-d" "1"; }
        Alt+XF86MonBrightnessUp { spawn "brightnessctl" "set" "+1%"; }
        Alt+XF86MonBrightnessDown { spawn "brightnessctl" "set" "1%-"; }

        // Media control
        XF86AudioNext { spawn "playerctl" "next"; }
        XF86AudioPlay { spawn "playerctl" "play-pause"; }
        XF86AudioPause { spawn "playerctl" "play-pause"; }
        XF86AudioPrev { spawn "playerctl" "previous"; }
    }
  '';
}
