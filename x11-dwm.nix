{ config, pkgs, ... }:

{
  # X11 packages for DWM and i3 environment
  environment.systemPackages = with pkgs; [
    # Picom compositor (for DWM and i3)
    picom        # Compositor for rounded corners and transparency
    
    # Wallpaper tools for X11
    feh          # For setting wallpapers in X11
    
    # Application launchers for X11
    dmenu        # Simple application launcher for DWM
    rofi         # More feature-rich launcher (X11 compatible)
    
    # Screenshot tools for X11
    scrot        # Screenshot utility for i3
    
    # X11 session support for greetd/startx
    xorg.xinit   # Provides startx command
    xorg.xauth   # X11 authentication
  ];

  # Enable X11 server with both dwm and i3 window managers
  services.displayManager.defaultSession = "none+i3";
  services.xserver = {
    displayManager = {
      startx.enable=true;
      setupCommands = ''
        ${pkgs.xorg.xrandr}/bin/xrandr --output Virtual-1 --auto
        ${pkgs.picom}/bin/picom --config /etc/xdg/picom.conf --daemon
      '';
      sessionCommands = ''
        # Load Xresources
        ${pkgs.xorg.xrdb}/bin/xrdb -merge ~/.Xresources
        
        # Set wallpaper
        if [ -f "$HOME/.local/share/wallpapers/1-kanagawa.jpg" ]; then
          ${pkgs.feh}/bin/feh --bg-fill "$HOME/.local/share/wallpapers/1-kanagawa.jpg" &
        else
          # Fallback to solid Kanagawa background color
          ${pkgs.xorg.xsetroot}/bin/xsetroot -solid "#1f1f28" &
        fi
      '';
    };

    enable = true;
    dpi = config.machine.dpi;
    
    windowManager.dwm = {
      enable = true;
      package = pkgs.writeShellScriptBin "dwm" ''
        # Set optimal resolution automatically
        # Get the highest available resolution for the primary display
        PRIMARY_OUTPUT=$(${pkgs.xorg.xrandr}/bin/xrandr | grep " connected primary" | cut -d' ' -f1)
        if [ -n "$PRIMARY_OUTPUT" ]; then
          # Get the highest resolution (first one in the list after the output name)
          BEST_RES=$(${pkgs.xorg.xrandr}/bin/xrandr | grep "^$PRIMARY_OUTPUT" -A 20 | grep "^ " | head -1 | awk '{print $1}')
          if [ -n "$BEST_RES" ]; then
            echo "Setting resolution to $BEST_RES on $PRIMARY_OUTPUT"
            ${pkgs.xorg.xrandr}/bin/xrandr --output "$PRIMARY_OUTPUT" --mode "$BEST_RES" --primary
          fi
        fi
        
        # St doesn't need a server like foot, so we skip terminal server startup
        
        # Picom is now started in setupCommands before DWM loads
        # Wallpaper is now set in sessionCommands as user
        
        # Wait a moment for services to start
        sleep 1
        
        # Start the actual DWM with alwayscenter patch
        exec ${pkgs.dwm.overrideAttrs (oldAttrs: rec {
          patches = (oldAttrs.patches or []) ++ [
            (pkgs.fetchpatch {
              url = "https://dwm.suckless.org/patches/alwayscenter/dwm-alwayscenter-20200625-f04cac6.diff";
              sha256 = "sha256-xQEwrNphaLOkhX3ER09sRPB3EEvxC73oNWMVkqo4iSY=";
            })
            (pkgs.fetchpatch {
              url = "https://dwm.suckless.org/patches/anybar/dwm-anybar-20200810-bb2e722.diff";
              sha256 = "0n2pqy0lwvkkiz9lc9q4qkbyb1rx8a8mhj51g541n5fri5pv1xb0";
            })
          ];
          postPatch = ''
            cp ${./dwm-config.h} config.def.h
          '';
        })}/bin/dwm
      '';
    };
    
    # Enable i3 window manager
    windowManager.i3 = {
      enable = true;
      package = pkgs.i3;
      extraPackages = with pkgs; [
        i3status  # Status bar
        i3lock    # Screen locker
        i3blocks  # Alternative status bar
      ];
    };
    
    desktopManager.xterm.enable = false;  # Disable xterm as default
    # Set keyboard layout
    xkb = {
      layout = "us";
      variant = "mac";
    };
  };

  # Enable input services
  services.libinput = {
    enable = true;
    touchpad.tapping = true;
    touchpad.naturalScrolling = false;
    touchpad.scrollMethod = "twofinger";
    touchpad.disableWhileTyping = true;
    touchpad.clickMethod = "clickfinger";
  };

  # Enable essential services
  services.dbus.enable = true;

  # Rofi configuration for X11/DWM (matching wofi settings)
  environment.etc."xdg/rofi/config.rasi".text = ''
    configuration {
      modi: "drun";
      width: 600;
      height: 400;
      lines: 15;
      columns: 1;
      font: "CaskaydiaMono Nerd Font 14";
      show-icons: true;
      icon-theme: "Papirus";
      terminal: "st";
      drun-display-format: "{icon} {name}";
      disable-history: false;
      hide-scrollbar: true;
      sidebar-mode: false;
      case-sensitive: false;
      cycle: true;
      theme: "kanagawa";
      location: 0;
      fixed-num-lines: true;
      click-to-exit: true;
      show-match: false;
      line-margin: 2;
      line-padding: 1;
      separator-style: "none";
      scrollbar-width: 0;
      matching: "fuzzy";
      sort: true;
      levenshtein-sort: true;
      normalize-match: true;
      run-command: "{cmd}";
      run-shell-command: "{terminal} -e {cmd}";
    }
  '';

  # Kanagawa theme for Rofi (matching wofi appearance)
  environment.etc."xdg/rofi/themes/kanagawa.rasi".text = ''
    /* Kanagawa Color Palette (matching wofi exactly) */
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
        
        background-color: transparent;
        border: 0;
        margin: 0;
        padding: 0;
        spacing: 0;
    }

    window {
        background-color: rgba(31, 31, 40, 0.95);
        border: 2px solid var(--purple);
        border-radius: 12px;
        location: center;
        width: 600px;
        height: 400px;
        font: "CaskaydiaMono Nerd Font 14";
    }

    mainbox {
        background-color: transparent;
        border: 0;
        border-radius: 0;
        children: [ inputbar, listview ];
    }

    inputbar {
        background-color: transparent;
        border: 2px solid var(--bg3);
        border-radius: 8px;
        margin: 5px;
        padding: 10px;
        spacing: 0;
        text-color: var(--fg);
        children: [ entry ];
    }

    inputbar:focus {
        border-color: var(--blue);
        box-shadow: 0 0 10px rgba(126, 156, 216, 0.3);
    }

    entry {
        background-color: transparent;
        border: 0;
        border-radius: 0;
        padding: 0;
        text-color: var(--fg);
        placeholder-color: var(--fg-dim);
        placeholder: "Search...";
        font: "CaskaydiaMono Nerd Font 16";
    }

    listview {
        background-color: transparent;
        border: 0;
        border-radius: 0;
        columns: 1;
        lines: 15;
        margin: 5px;
        padding: 0;
        scrollbar: false;
        spacing: 2px;
    }

    element {
        background-color: transparent;
        border: 0;
        border-radius: 8px;
        margin: 2px;
        padding: 8px;
        spacing: 10px;
        text-color: var(--fg);
        children: [ element-icon, element-text ];
    }

    element normal.normal {
        background-color: transparent;
        text-color: var(--fg);
    }

    element normal.urgent {
        background-color: var(--red);
        text-color: var(--fg);
    }

    element normal.active {
        background-color: var(--green);
        text-color: var(--bg1);
    }

    element selected.normal {
        background-color: var(--bg2);
        border: 1px solid var(--purple);
        text-color: var(--fg);
        box-shadow: 0 2px 8px rgba(149, 127, 184, 0.2);
    }

    element selected.urgent {
        background-color: var(--red);
        text-color: var(--fg);
    }

    element selected.active {
        background-color: var(--green);
        text-color: var(--bg1);
    }

    element alternate.normal {
        background-color: transparent;
        text-color: var(--fg);
    }

    element alternate.urgent {
        background-color: var(--red);
        text-color: var(--fg);
    }

    element alternate.active {
        background-color: var(--green);
        text-color: var(--bg1);
    }

    element-icon {
        background-color: transparent;
        size: 48px;
        text-color: inherit;
        border-radius: 6px;
    }

    element-text {
        background-color: transparent;
        expand: true;
        horizontal-align: 0;
        margin: 0 0 0 10px;
        text-color: inherit;
        vertical-align: 0.5;
        font-weight: 500;
    }

    element selected element-text {
        font-weight: 600;
    }

    scrollbar {
        background-color: var(--bg3);
        border: 0;
        handle-color: var(--purple);
        handle-width: 8px;
        margin: 0 0 0 8px;
        padding: 0;
    }

    message {
        background-color: transparent;
        border: 0;
        margin: 5px;
        padding: 0;
    }

    textbox {
        background-color: transparent;
        padding: 8px 12px;
        text-color: var(--fg);
        vertical-align: 0.5;
    }
  '';

  # Polybar configuration for DWM
  environment.etc."polybar/config.ini".text = ''
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
  '';

  # Picom configuration for DWM only
  environment.etc."xdg/picom.conf".text = ''
    # Picom configuration for DWM
    # Performance optimized for Parallels VM

    # Backend and performance
    backend = "glx";
    vsync = true;
    glx-no-stencil = true;
    glx-copy-from-front = false;

    # Fade animations
    fading = true;
    fade-delta = 4;
    fade-in-step = 0.028;
    fade-out-step = 0.03;

    # Shadow (disabled for performance)
    shadow = false;
    shadow-opacity = 0.75;

    # Transparency
    active-opacity = 1.0;
    inactive-opacity = 0.95;
    frame-opacity = 1.0;
    menu-opacity = 0.95;

    # Rounded corners
    corner-radius = 10;
    rounded-corners-exclude = [
        "class_g = 'Polybar'",
        "class_g = 'dmenu'",
        "class_g = 'Dunst'",
        "name = 'Notification'",
        "_GTK_FRAME_EXTENTS@:c"
    ];

    # Per-application opacity rules
    opacity-rule = [
        "95:class_g = 'st'",             # Terminal transparency
        "100:class_g = 'Brave-browser'", # Browser opaque
        "95:class_g = 'Thunar'",         # File manager
        "100:class_g = 'dwm'",           # DWM bar opaque
        "90:class_g = 'dmenu'",          # dmenu slightly transparent
    ];

    # Blur (disabled for performance in VM)
    blur-background = false;
    blur-method = "dual_kawase";
    blur-strength = 3;

    # Exclude certain window types from effects
    wintypes: {
        tooltip = { fade = true; shadow = false; opacity = 0.95; focus = true; full-shadow = false; };
        dock = { shadow = false; };
        dnd = { shadow = false; };
        popup_menu = { opacity = 0.95; };
        dropdown_menu = { opacity = 0.95; };
    };

    # Detect WM
    detect-rounded-corners = true;
    detect-client-opacity = true;
    detect-transient = true;
    detect-client-leader = true;
  '';
}
