{
  config,
  pkgs,
  lib,
  isVm ? false,
  lockScreen ? false,
  useDms ? false,
  ...
}:

let
  # Single-output hosts (the VM) don't have DP-1/DP-2, so pinning
  # workspaces to those outputs makes niri stack all 18 named
  # workspaces onto the lone Virtual-1 output. Declare a smaller,
  # unpinned set instead — niri places them on whichever output is
  # present.
  workspaceBlock =
    if isVm then
      ''
        // Single-output VM: 5 persistent workspaces, no open-on-output
        // (only Virtual-1 exists, so niri places them there anyway).
        workspace "1" { }
        workspace "2" { }
        workspace "3" { }
        workspace "4" { }
        workspace "5" { }
      ''
    else
      ''
        // 9 persistent workspaces per output. The Mod+1..9 bindings use
        // niri's per-output index (focus-workspace <int>), so the names
        // below are just unique labels — Mod+1 on DP-1 lands on "1", on
        // DP-2 it lands on "p1". DP-1 = landscape (right), DP-2 = portrait
        // (left); without open-on-output niri stacks every workspace on
        // the first-enumerated output.
        workspace "1" {
            open-on-output "DP-1"
        }
        workspace "2" {
            open-on-output "DP-1"
        }
        workspace "3" {
            open-on-output "DP-1"
        }
        workspace "4" {
            open-on-output "DP-1"
        }
        workspace "5" {
            open-on-output "DP-1"
        }
        workspace "6" {
            open-on-output "DP-1"
        }
        workspace "7" {
            open-on-output "DP-1"
        }
        workspace "8" {
            open-on-output "DP-1"
        }
        workspace "9" {
            open-on-output "DP-1"
        }
        workspace "p1" {
            open-on-output "DP-2"
        }
        workspace "p2" {
            open-on-output "DP-2"
        }
        workspace "p3" {
            open-on-output "DP-2"
        }
        workspace "p4" {
            open-on-output "DP-2"
        }
        workspace "p5" {
            open-on-output "DP-2"
        }
        workspace "p6" {
            open-on-output "DP-2"
        }
        workspace "p7" {
            open-on-output "DP-2"
        }
        workspace "p8" {
            open-on-output "DP-2"
        }
        workspace "p9" {
            open-on-output "DP-2"
        }
      '';
in
{
  # Always install hyprpolkitagent. DMS 1.4.6 ships a PolkitAuthModal
  # but it logs "Polkit not available — authentication prompts disabled.
  # This requires a newer version of Quickshell." and registers nothing
  # against polkit. Until Quickshell exposes polkit primitives, we run
  # hyprpolkitagent on DMS hosts too. Drop this once DMS's PolkitService
  # actually owns the auth-agent slot.
  home.packages = [ pkgs.hyprpolkitagent ];

  # Niri configuration with Hyprland-like keybindings
  xdg.configFile."niri/config.kdl".text = ''
    ${workspaceBlock}

    // Monitor/Output configuration (matching Hyprland 2.0 scale)
    output "Virtual-1" {
        // Default configuration for all outputs
        scale 2.0 
    }


    // DP-2: Dell S2725QS, 27" 4K, mounted in portrait to the left of DP-1.
    // Logical size after scale=1.5 + 90° rotation = 1440 wide x 2560 tall.
    // Flip transform to "90" if the image lands upside-down.
    output "DP-2" {
        mode "3840x2160@120.000"
        scale 1.5
        transform "270"
        position x=0 y=0
    }

    // DP-1: Guangxi 32M2V, 32" 4K, landscape, right of DP-2.
    // Logical 3072x1728 at scale=1.25; placed flush right of DP-2.
    output "DP-1" {
        mode "3840x2160@144.000"
        scale 1.25
        position x=1440 y=0
    }

    // Define workspaces with numbers

    // Spawn programs on startup (others managed by systemd user services).
    // The polkit auth agent must be spawned by niri itself (not via
    // systemd user service) so it lands in the graphical logind session's
    // cgroup — polkit refuses auth-agent listeners that aren't attached
    // to a class=user logind session. DMS itself is also spawned here
    // (when active) for the same scope reason, even though its
    // PolkitService is currently a no-op on the Quickshell version we
    // run — see home.packages above for context.
    spawn-at-startup "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent"
    ${lib.optionalString useDms ''
      spawn-at-startup "${config.programs.dank-material-shell.package}/bin/dms" "run" "--session"
    ''}
    // niri runs in the logind session scope (not niri.service), so the
    // user-systemd graphical-session.target is never armed and any unit
    // with Requisite=graphical-session.target (e.g. xdg-desktop-portal-gnome)
    // refuses to start — which breaks screen sharing in browsers.
    // graphical-session.target itself has RefuseManualStart=yes, so we
    // can't pull it up directly; instead we start niri-graphical-session
    // (defined in system/desktop.nix) which BindsTo+Before the target
    // and pulls it active for the duration of the niri session.
    spawn-at-startup "${pkgs.dbus}/bin/dbus-update-activation-environment" "--systemd" "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP" "XDG_SESSION_TYPE" "DISPLAY"
    spawn-at-startup "systemctl" "--user" "start" "niri-graphical-session.service"
    spawn-at-startup "prlcc"


    // Environment variables
    environment {
        QT_QPA_PLATFORM "wayland"
        QT_QPA_PLATFORMTHEME "qt6ct"
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
        // Warp the cursor to the focused window's center on cross-window
        // focus changes — gives a visible "which monitor am I on" cue when
        // switching outputs via Mod+Ctrl+Arrow. center-xy only warps when
        // the cursor is outside the newly focused window, so intra-monitor
        // column moves stay calm.
        warp-mouse-to-focus mode="center-xy"
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
        
        default-column-width { proportion 1.0; }

        preset-column-widths {
            proportion 0.25
            proportion 0.5
            proportion 0.75
            proportion 1.0
        }

        focus-ring {
            width 4
            active-color "#cdd6f4"  // Catppuccin Mocha text
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

    // Transparency: focused fully opaque, unfocused dimmed
    window-rule {
        match is-active=true
        opacity 1.0
    }

    window-rule {
        match is-active=false
        opacity 0.92
        background-effect {
            blur true
        }
    }

    // Brave: opaque when focused, slight dim when unfocused
    window-rule {
        match app-id=r#"^brave"#
        opacity 1.0
    }

    window-rule {
        match app-id=r#"^brave"# is-active=false
        opacity 0.95
    }

    window-rule {
        match app-id="com.mitchellh.ghostty"
        default-column-width { proportion 0.5; }
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

    ${lib.optionalString useDms ''
      window-rule {
          match app-id="org.quickshell" title="Settings"
          open-floating true
          default-column-width { fixed 1200; }
          open-on-output "current"
      }
    ''}

    window-rule {
        match is-window-cast-target=true

        focus-ring {
            active-color "#f38ba8"
            inactive-color "#7d0d2d"
        }

        shadow {
            on
            softness 0
            offset x=0 y=0
            spread 4

            color "#7d0d2dff"
        }

        tab-indicator {
            active-color "#f38ba8"
            inactive-color "#7d0d2d"
        }
    }

    ${lib.optionalString useDms ''
      // Frosted-glass effect on the DMS bar only. Earlier versions of
      // this rule matched layer="top"/"overlay" globally, but DMS
      // modals (DankModal.qml) spawn a fullscreen "*:clickcatcher"
      // layer-shell surface for click-outside-to-dismiss; with niri's
      // blur applied behind it, the rest of the screen visually
      // disappeared while a dialog was open. DMS handles its own
      // backdrop blur for popouts/control-center via blurEnabled, so
      // we only need niri's compositor blur for the bar itself.
      layer-rule {
          match namespace="dms:bar"
          background-effect {
              blur true
          }
      }
    ''}

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
        // Applications (ghostty is the default terminal; gtk-single-instance
        // makes subsequent launches reuse the existing process)
        Mod+Return { spawn "ghostty"; }
        Mod+Shift+T { spawn "thunar"; }
        Mod+Shift+B { spawn "browser-default"; }
        Mod+Shift+M { spawn "bookmarks"; }
        Mod+Shift+N { spawn "notes"; }
        Mod+Backslash { spawn "bitwarden"; }
        Mod+Shift+A { spawn "browser-app" "https://grok.com"; }
        Mod+Shift+X { spawn "browser-app" "https://x.com"; }
        Mod+S { spawn "window-switcher"; }

        // Menu and launcher
        Mod+Space { spawn "fuzzel"; }
        Mod+D { spawn "fuzzel"; }
        ${
          if useDms then
            ''Mod+Escape { spawn "dms" "ipc" "call" "powermenu" "toggle"; }''
          else
            ''Mod+Escape { spawn "wlogout"; }''
        }

        // Window management
        Mod+W { close-window; }
        Mod+Shift+Q { quit; }
        Mod+F9 { fullscreen-window; }
        Mod+Ctrl+F {fullscreen-window; }
        Mod+F { maximize-column; }
        Mod+V { toggle-window-floating; }

        // Focus movement (arrow keys and vim keys). Horizontal motion
        // falls through to the neighboring monitor when at the edge.
        Mod+Left repeat=true { focus-column-or-monitor-left; }
        Mod+Right repeat=true { focus-column-or-monitor-right; }
        Mod+Up repeat=true { focus-window-or-workspace-up; }
        Mod+Down repeat=true { focus-window-or-workspace-down; }
        Mod+h repeat=true { focus-column-or-monitor-left; }
        Mod+l repeat=true { focus-column-or-monitor-right; }
        Mod+k repeat=true { focus-window-or-workspace-up; }
        Mod+j repeat=true { focus-window-or-workspace-down; }

        Mod+c {toggle-column-tabbed-display; }

        // Window movement (vim keys and arrows). Horizontal motion
        // carries the column across to the neighboring monitor at the
        // edge.
        Mod+Shift+Left repeat=true { move-column-left-or-to-monitor-left; }
        Mod+Shift+Right repeat=true { move-column-right-or-to-monitor-right; }
        Mod+Shift+Up repeat=true { move-window-up-or-to-workspace-up; }
        Mod+Shift+Down repeat=true { move-window-down-or-to-workspace-down; }
        Mod+Shift+H repeat=true { move-column-left-or-to-monitor-left; }
        Mod+Shift+L repeat=true { move-column-right-or-to-monitor-right; }
        Mod+Shift+K repeat=true { move-window-up-or-to-workspace-up; }
        Mod+Shift+J repeat=true { move-window-down-or-to-workspace-down; }

        // Consume or expel window (bracket keys)
        Mod+BracketLeft { consume-or-expel-window-left; }
        Mod+BracketRight { consume-or-expel-window-right; }

        // Multi-monitor: focus and send windows across outputs.
        // Arrow-only because Mod+Ctrl+L collides with the lock binding.
        Mod+Ctrl+Left  { focus-monitor-left; }
        Mod+Ctrl+Right { focus-monitor-right; }
        Mod+Ctrl+Up    { focus-monitor-up; }
        Mod+Ctrl+Down  { focus-monitor-down; }
        Mod+Ctrl+Shift+Left  { move-column-to-monitor-left; }
        Mod+Ctrl+Shift+Right { move-column-to-monitor-right; }
        Mod+Ctrl+Shift+Up    { move-column-to-monitor-up; }
        Mod+Ctrl+Shift+Down  { move-column-to-monitor-down; }

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

        // Jump to first/last column in current workspace
        Mod+Home { focus-column-first; }
        Mod+End { focus-column-last; }

        // Column width adjustment (similar to Hyprland resize)
        Mod+R { switch-preset-column-width; }
        Mod+Minus repeat=true { set-column-width "-100"; }
        Mod+Equal repeat=true { set-column-width "+100"; }
        Mod+Shift+Minus repeat=true { set-window-height "-100"; }
        Mod+Shift+Equal repeat=true { set-window-height "+100"; }

        // Screenshots
        // Mod+Shift+S → niri-native interactive overlay piped through satty.
        // Mod+Shift+F keeps the existing hyprshot-based output capture.
        Mod+Shift+S { spawn "screenshot-niri"; }
        Mod+Shift+F { spawn "screenshot" "output"; }
        
        ${lib.optionalString lockScreen (
          if useDms then
            ''
              // Lock screen via DMS (dms-settings.json owns the timeouts).
              Mod+Ctrl+L { spawn "dms" "ipc" "call" "lock" "lock"; }
            ''
          else
            ''
              // Lock screen via swaylock (lockscreen.nix configures it).
              Mod+Ctrl+L { spawn "swaylock" "-f"; }
            ''
        )}

        // Notification control
        Mod+Semicolon { spawn "makoctl" "restore"; }

        // Waybar toggle
        Mod+Y { spawn "sh" "-c" "systemctl --user is-active --quiet wl-waybar && systemctl --user stop wl-waybar || systemctl --user start wl-waybar"; }
        Mod+Shift+Y { spawn "sh" "-c" "systemctl --user is-active --quiet wl-eww && systemctl --user stop wl-eww || systemctl --user start wl-eww"; }
        ${lib.optionalString useDms ''
          // DMS surface toggles
          // Theme toggle does two things in sequence:
          //   1. `dms ipc call theme toggle` flips DMS's isLightMode,
          //      which fires SessionData.syncWallpaperForCurrentMode()
          //      → swaps wallpapers + regenerates matugen templates.
          //   2. `darkman toggle` writes gsettings color-scheme so the
          //      xdg-desktop-portal Settings value reflects the new
          //      mode. DMS itself skips that write when matugen is
          //      available (Theme.qml:1001-1003), leaving GTK/Qt apps
          //      that read from the portal out of sync — darkman fills
          //      that gap.
          Mod+Shift+D { spawn "sh" "-c" "dms ipc call theme toggle; darkman toggle"; }
          Mod+Comma   { spawn "dms" "ipc" "call" "dash" "toggle" "overview"; }
          Mod+Period  { spawn "dms" "ipc" "call" "control-center" "toggle"; }
          Mod+N       { spawn "dms" "ipc" "call" "notepad" "toggle"; }
        ''}

        // Media keys — SwayOSD when in waybar/eww mode, wpctl/brightnessctl
        // direct when DMS owns the OSD (DMS shows its own via pipewire monitoring).
        ${
          if useDms then
            ''
              XF86AudioRaiseVolume { spawn "wpctl" "set-volume" "-l" "1.5" "@DEFAULT_AUDIO_SINK@" "5%+"; }
              XF86AudioLowerVolume { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"; }
              XF86AudioMute { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }
              XF86AudioMicMute { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SOURCE@" "toggle"; }
              XF86MonBrightnessUp { spawn "brightnessctl" "set" "5%+"; }
              XF86MonBrightnessDown { spawn "brightnessctl" "set" "5%-"; }
            ''
          else
            ''
              XF86AudioRaiseVolume { spawn "swayosd-client" "--output-volume" "raise"; }
              XF86AudioLowerVolume { spawn "swayosd-client" "--output-volume" "lower"; }
              XF86AudioMute { spawn "swayosd-client" "--output-volume" "mute-toggle"; }
              XF86AudioMicMute { spawn "pamixer" "--default-source" "-t"; }
              XF86MonBrightnessUp { spawn "swayosd-client" "--brightness" "raise"; }
              XF86MonBrightnessDown { spawn "swayosd-client" "--brightness" "lower"; }
            ''
        }

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
    ${lib.optionalString useDms ''
      // DMS writes per-feature KDL snippets to ~/.config/niri/dms/ and
      // refuses to apply settings (cursor, matugen colors, alt-tab,
      // wallpaper blur) until they're included here. Placed last so DMS
      // overrides any earlier layout/colors set by Nix.
      include "dms/cursor.kdl"
      include "dms/colors.kdl"
      include "dms/alttab.kdl"
      include "dms/wpblur.kdl"
    ''}
  '';
}
