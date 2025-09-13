{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

{
  # Status bar - Waybar (extracted from wayland.nix)
  programs.waybar = {
    enable = true;
    systemd.enable = false;
  };

  # Separate configuration files for different window managers
  xdg.configFile = {
    "waybar/hyprland-config.json".text = builtins.toJSON {
        reload_style_on_change = true;
        layer = "top";
        position = "top";
        spacing = 0;
        height = 26;
        margin-top = 8;
        modules-left = [
          "clock"
          "hyprland/window"
        ];
        modules-center = [
          "hyprland/workspaces"
        ];
        modules-right = [
          "network"
          "pulseaudio"
          "cpu"
          "memory"
          "disk"
          "idle_inhibitor"
          "privacy"
          "systemd-failed-units"
          "group/tray-expander"
          "battery"
        ];

        "hyprland/workspaces" = {
          on-click = "activate";
          format = "{name}";
          format-icons = {
            default = "";
            active = "{name}";
          };
          persistent-workspaces = {
            "1" = [ ];
            "2" = [ ];
            "3" = [ ];
            "4" = [ ];
            "5" = [ ];
          };
        };

        "hyprland/window" = {
          format = "{}";
          max-length = 50;
          separate-outputs = true;
        };

        "cpu" = {
          interval = 5;
          format = "󰻠 {usage}%";
          tooltip-format = "CPU Usage: {usage}%";
          on-click = "alacritty msg create-window -e btop";
        };

        "memory" = {
          interval = 5;
          format = "󰍛 {used:0.1f}G ({percentage}%)";
          tooltip-format = "Memory: {used:0.1f}G / {total:0.1f}G ({percentage}%)";
          on-click = "alacritty msg create-window -e btop";
        };

        "disk" = {
          interval = 30;
          format = "󰋊 {used} ({percentage_used}%)";
          path = "/";
          tooltip-format = "Disk: {used} / {total} ({percentage_used}%)";
          on-click = "alacritty msg create-window -e btop";
        };

        "clock" = {
          format = "{:%a %b %d %I:%M %p}";
          format-alt = "{:%A %B %d, %Y %I:%M:%S %p}";
          tooltip = false;
        };

        "network" = {
          format-icons = [
            "󰤯"
            "󰤟"
            "󰤢"
            "󰤥"
            "󰤨"
          ];
          format = "󰀂 ⇣{bandwidthDownBytes:>6} ⇡{bandwidthUpBytes:>6}";
          format-wifi = "󰀂 ⇣{bandwidthDownBytes:>6} ⇡{bandwidthUpBytes:>6}";
          format-ethernet = "󰀂 ⇣{bandwidthDownBytes:>6} ⇡{bandwidthUpBytes:>6}";
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
          full-at = 80;
          states = {
            good = 95;
            warning = 30;
            critical = 20;
          };
          format = "{icon} {capacity}%";
          format-charging = "󰂄 {capacity}%";
          format-plugged = "󰂄 {capacity}%";
          format-alt = "{time} {icon}";
          format-good = "";
          format-full = "󰁹 Full";
          format-icons = [
            "󰁺"
            "󰁻"
            "󰁼"
            "󰁽"
            "󰁾"
            "󰁿"
            "󰂀"
            "󰂁"
            "󰂂"
            "󰁹"
          ];
        };

        "pulseaudio" = {
          format = "{icon} {volume}%";
          format-bluetooth = "{volume}% {icon}";
          format-muted = "󰸈";
          format-icons = {
            headphone = "󰋋";
            hands-free = "󰋎";
            headset = "󰋎";
            phone = "";
            portable = "";
            car = "";
            default = [
              "󰕿"
              "󰖀"
              "󰕾"
            ];
          };
          on-click = "pamixer -t";
          on-click-right = "pavucontrol";
          scroll-step = 5;
        };

        "group/tray-expander" = {
          orientation = "horizontal";
          modules = [
            "custom/expand-icon"
            "tray"
          ];
          drawer = {
            transition-duration = 500;
            children-class = "tray-drawer";
            transition-left-to-right = true;
          };
        };

        "custom/expand-icon" = {
          format = "▶️";
          tooltip = false;
        };

        "tray" = {
          icon-size = 12;
          spacing = 12;
          show-passive-items = false;
        };

        "idle_inhibitor" = {
          format = "{icon}";
          format-icons = {
            activated = "󰒳";
            deactivated = "󰒲";
          };
          tooltip-format-activated = "Idle inhibitor: ON";
          tooltip-format-deactivated = "Idle inhibitor: OFF";
        };

        "privacy" = {
          icon-spacing = 4;
          icon-size = 12;
          transition-duration = 250;
          modules = [
            {
              type = "screenshare";
              tooltip = true;
              tooltip-icon-size = 24;
            }
            {
              type = "audio-out";
              tooltip = true;
              tooltip-icon-size = 24;
            }
            {
              type = "audio-in";
              tooltip = true;
              tooltip-icon-size = 24;
            }
          ];
        };

        "systemd-failed-units" = {
          hide-on-ok = false;
          format = "✗ {nr_failed}";
          format-ok = "✓";
          system = true;
          user = true;
        };
    };

    "waybar/niri-config.json".text = builtins.toJSON {
        reload_style_on_change = true;
        layer = "top";
        position = "top";
        spacing = 0;
        height = 26;
        margin-top = 8;
        modules-left = [
          "niri/workspaces"
          "niri/window"
        ];
        modules-center = [ ];
        modules-right = [
          "network"
          "pulseaudio"
          "cpu"
          "memory"
          "disk"
          "group/tray-expander"
          "battery"
          "clock"
        ];

        "niri/workspaces" = {
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
            "1" = [ ];
            "2" = [ ];
            "3" = [ ];
            "4" = [ ];
            "5" = [ ];
          };
        };

        "niri/window" = {
          format = "{}";
          max-length = 50;
        };

        "cpu" = {
          interval = 5;
          format = "󰻠 {usage}%";
          tooltip-format = "CPU Usage: {usage}%";
          on-click = "alacritty msg create-window -e btop";
        };

        "memory" = {
          interval = 5;
          format = "󰍛 {used:0.1f}G ({percentage}%)";
          tooltip-format = "Memory: {used:0.1f}G / {total:0.1f}G ({percentage}%)";
          on-click = "alacritty msg create-window -e btop";
        };

        "disk" = {
          interval = 30;
          format = "󰋊 {used} ({percentage_used}%)";
          path = "/";
          tooltip-format = "Disk: {used} / {total} ({percentage_used}%)";
          on-click = "alacritty msg create-window -e btop";
        };

        "clock" = {
          format = "{:%a %b %d %I:%M %p}";
          format-alt = "{:%A %B %d, %Y %I:%M:%S %p}";
          tooltip = false;
        };

        "network" = {
          format-icons = [
            "󰤯"
            "󰤟"
            "󰤢"
            "󰤥"
            "󰤨"
          ];
          format = "󰀂 ⇣{bandwidthDownBytes:>6} ⇡{bandwidthUpBytes:>6}";
          format-wifi = "󰀂 ⇣{bandwidthDownBytes:>6} ⇡{bandwidthUpBytes:>6}";
          format-ethernet = "󰀂 ⇣{bandwidthDownBytes:>6} ⇡{bandwidthUpBytes:>6}";
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
          full-at = 80;
          states = {
            good = 95;
            warning = 30;
            critical = 20;
          };
          format = "{icon} {capacity}%";
          format-charging = "󰂄 {capacity}%";
          format-plugged = "󰂄 {capacity}%";
          format-alt = "{time} {icon}";
          format-good = "";
          format-full = "󰁹 Full";
          format-icons = [
            "󰁺"
            "󰁻"
            "󰁼"
            "󰁽"
            "󰁾"
            "󰁿"
            "󰂀"
            "󰂁"
            "󰂂"
            "󰁹"
          ];
        };

        "pulseaudio" = {
          format = "{icon} {volume}%";
          format-bluetooth = "{volume}% {icon}";
          format-muted = "󰸈";
          format-icons = {
            headphone = "󰋋";
            hands-free = "󰋎";
            headset = "󰋎";
            phone = "";
            portable = "";
            car = "";
            default = [
              "󰕿"
              "󰖀"
              "󰕾"
            ];
          };
          on-click = "pamixer -t";
          on-click-right = "pavucontrol";
          scroll-step = 5;
        };

        "group/tray-expander" = {
          orientation = "horizontal";
          modules = [
            "custom/expand-icon"
            "tray"
          ];
          drawer = {
            transition-duration = 500;
            children-class = "tray-drawer";
            transition-left-to-right = true;
          };
        };

        "custom/expand-icon" = {
          format = "▶️";
          tooltip = false;
        };

        "tray" = {
          icon-size = 12;
          spacing = 12;
          show-passive-items = false;
        };
    };

    "waybar/style.css".text = ''
      * {
        background-color: transparent;
        color: #dcd7ba;
        border: none;
        border-radius: 0;
        min-height: 0;
        font-family: CaskaydiaMono Nerd Font;
        font-size: 12px;
      }

      .modules-left {
        margin-left: 8px;
      }

      #workspaces {
        background-color: #1f1f28;
        border-radius: 8px;
        padding: 2px 4px;
        margin: 1px 0;
      }

      .modules-center {
        background-color: transparent;
        border-radius: 8px;
        padding: 1px 4px;
      }

      .modules-right {
        margin-right: 8px;
      }

      #workspaces button {
        all: initial;
        padding: 2px;
        margin: 0 1px;
        min-width: 12px;
        min-height: 12px;
        color: #2a2a2a;
        background-color: #2a2a2a;
        border-radius: 50%;
        transition: all 0.2s cubic-bezier(0.4, 0.0, 0.2, 1);
        border: none;
        font-size: 9px;
        font-weight: 500;
      }

      #workspaces button.empty {
        opacity: 0.4;
        background-color: #1f1f1f;
        color: #1f1f1f;
        padding: 2px;
        min-width: 8px;
        min-height: 8px;
        border-radius: 50%;
        font-size: 9px;
      }

      #workspaces button.active {
        color: #1f1f28;
        background: linear-gradient(135deg, #7fb4ca 0%, #658594 100%);
        border-radius: 5px;
        font-weight: 600;
        padding: 3px 10px;
        min-width: 24px;
        min-height: 14px;
        box-shadow: 0 2px 6px rgba(127, 180, 202, 0.4);
        font-size: 9px;
      }

      #workspaces button.focused {
        color: #ffffff;
        background: linear-gradient(135deg, #81c784 0%, #66bb6a 100%);
        border-radius: 6px;
        padding: 4px 10px;
        min-width: 24px;
        min-height: 16px;
        box-shadow: 0 2px 6px rgba(129, 199, 132, 0.3);
        font-size: 9px;
      }

      #workspaces button.urgent {
        color: #ffffff;
        background: linear-gradient(135deg, #ef5350 0%, #f44336 100%);
        border-radius: 6px;
        padding: 4px 10px;
        min-width: 24px;
        min-height: 16px;
        box-shadow: 0 3px 12px rgba(239, 83, 80, 0.6);
        font-size: 9px;
      }

      #workspaces button:hover {
        background: linear-gradient(135deg, #424242 0%, #303030 100%);
        color: #ffffff;
        padding: 3px 8px;
        min-width: 20px;
        min-height: 14px;
        border-radius: 7px;
        box-shadow: 0 1px 4px rgba(255, 255, 255, 0.1);
        font-size: 9px;
      }

      #window {
        margin: 0 4px;
        padding: 4px 12px;
        background-color: #16161d;
        color: #dcd7ba;
        border-radius: 8px;
        font-weight: normal;
        min-width: 200px;
        border: 1px solid #54546d;
      }

      #tray,
      #cpu,
      #battery,
      #memory,
      #disk,
      #network,
      #pulseaudio,
      #idle_inhibitor,
      #privacy,
      #systemd-failed-units,
      #custom-media {
        min-width: 12px;
        margin: 0 4px;
        padding: 2px 8px;
        border-radius: 8px;
        background-color: #1f1f28;
        color: #dcd7ba;
        font-weight: 500;
      }

      #network {
        background-color: #76946a;
        color: #1f1f28;
      }

      #network.disconnected {
        background-color: #c34043;
        color: #dcd7ba;
      }

      #pulseaudio {
        background-color: #ffa066;
        color: #1f1f28;
      }

      #pulseaudio.muted {
        background-color: #727169;
        color: #dcd7ba;
      }

      #cpu {
        background-color: #7e9cd8;
        color: #1f1f28;
      }

      #memory {
        background-color: #957fb8;
        color: #1f1f28;
      }

      #disk {
        background-color: #c0a36e;
        color: #1f1f28;
      }

      #battery {
        background-color: #98bb6c;
        color: #1f1f28;
      }

      #battery.warning {
        background-color: #e6c384;
        color: #1f1f28;
      }

      #battery.critical {
        background-color: #c34043;
        color: #dcd7ba;
      }

      #idle_inhibitor {
        background-color: #e6c384;
        color: #1f1f28;
      }

      #idle_inhibitor.activated {
        background-color: #98bb6c;
        color: #1f1f28;
      }

      #privacy {
        background-color: #c34043;
        color: #dcd7ba;
      }

      #systemd-failed-units {
        background-color: #98bb6c;
        color: #1f1f28;
      }

      #systemd-failed-units.degraded {
        background-color: #c34043;
        color: #dcd7ba;
      }

      #custom-expand-icon {
        margin-right: 4px;
        background-color: #54546d;
        color: #dcd7ba;
        padding: 2px 8px;
        border-radius: 8px;
      }

      #tray {
        background-color: #54546d;
        color: #dcd7ba;
      }

      #clock {
        background-color: #7fb4ca;
        color: #1f1f28;
        margin-right: 8px;
        border-radius: 8px;
        padding: 2px 8px;
      }

      tooltip {
        padding: 8px;
        background-color: #1f1f28;
        border: 1px solid #54546d;
        border-radius: 6px;
        color: #dcd7ba;
      }

      /* Tray popup menu styling */
      menu {
        background-color: #1f1f28;
        border: 1px solid #54546d;
        border-radius: 6px;
        padding: 4px;
        color: #dcd7ba;
      }

      menu > menuitem {
        background-color: transparent;
        color: #dcd7ba;
        padding: 4px 8px;
        border-radius: 4px;
      }

      menu > menuitem:hover {
        background-color: #54546d;
        color: #dcd7ba;
      }

      menu > menuitem:disabled {
        color: #727169;
      }

      .hidden {
        opacity: 0;
      }

      .tray-drawer {
        transition: all 0.5s ease-in-out;
      }
    '';
  };
}