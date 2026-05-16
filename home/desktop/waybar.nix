{
  pkgs,
  lib,
  useDms ? false,
  ...
}:

let
  waybar-uptime = pkgs.writeShellScript "waybar-uptime" ''
    read s _ < /proc/uptime
    s=''${s%.*}
    d=$((s/86400))
    h=$((s%86400/3600))
    m=$((s%3600/60))
    if [ "$d" -gt 0 ]; then
      printf "%dd %dh %dm" "$d" "$h" "$m"
    elif [ "$h" -gt 0 ]; then
      printf "%dh %dm" "$h" "$m"
    else
      printf "%dm" "$m"
    fi
  '';
in
{
  # Status bar - Waybar. Under DMS, waybar is replaced entirely by
  # DankBar, so don't install the package or its bundled systemd unit
  # (which would auto-start at graphical-session.target regardless of
  # programs.waybar.systemd.enable=false).
  programs.waybar = lib.mkIf (!useDms) {
    enable = true;
    systemd.enable = false;
  };

  # Separate configuration files for different window managers
  xdg.configFile = lib.mkIf (!useDms) {
    "waybar/hyprland-config.json".text = builtins.toJSON {
      reload_style_on_change = true;
      layer = "top";
      position = "top";
      spacing = 0;
      height = 22;
      margin-top = 8;
      modules-left = [
        "hyprland/workspaces"
        "hyprland/window"
      ];
      modules-center = [
        "clock"
      ];
      modules-right = [
        "network"
        "pulseaudio"
        "cpu"
        "memory"
        "disk"
        "custom/uptime"
        "idle_inhibitor"
        "privacy"
        #        "systemd-failed-units"
        "tray"
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
        format = "󰻠  {usage}%";
        tooltip-format = "CPU Usage: {usage}%";
        on-click = "ghostty -e btm";
      };

      "memory" = {
        interval = 5;
        format = "󰍛  {used:0.1f}G ({percentage}%)";
        tooltip-format = "Memory: {used:0.1f}G / {total:0.1f}G ({percentage}%)";
        on-click = "ghostty -e btop";
      };

      "disk" = {
        interval = 30;
        format = "󰋊  {used} ({percentage_used}%)";
        path = "/";
        tooltip-format = "Disk: {used} / {total} ({percentage_used}%)";
        on-click = "ghostty -e btop";
      };

      "custom/uptime" = {
        exec = "${waybar-uptime}";
        interval = 60;
        format = "󰔟  {}";
        tooltip-format = "System uptime";
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
        interval = 5;
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
        format = "{icon}  {capacity}%";
        format-charging = "󰂄 {capacity}%";
        format-plugged = "󰂄 {capacity}%";
        format-alt = "{time} {icon}";
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
            "󰕿 "
            "󰖀 "
            "󰕾 "
          ];
        };
        on-click = "pamixer -t";
        on-click-right = "pavucontrol";
        scroll-step = 5;
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
        hide-on-ok = true;
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
      height = 22;
      margin-top = 8;
      modules-left = [
        "niri/workspaces"
        "niri/window"
      ];
      modules-center = [
        "clock"
      ];
      modules-right = [
        "network"
        "pulseaudio"
        "cpu"
        "memory"
        "disk"
        "custom/uptime"
        "idle_inhibitor"
        "privacy"
        #  "systemd-failed-units"
        "tray"
        "battery"
      ];

      "niri/workspaces" = {
        on-click = "activate";
        current-only = false;
        format = "{index}";
        expand = true;
        format-icons = {
          default = "";
          active = "{name}";
        };
      };

      "niri/window" = {
        format = "{}";
        max-length = 50;
      };

      "cpu" = {
        interval = 5;
        format = "󰻠  {usage}%";
        tooltip-format = "CPU Usage: {usage}%";
        on-click = "ghostty -e btm";
      };

      "memory" = {
        interval = 5;
        format = "󰍛  {used:0.1f}G ({percentage}%)";
        tooltip-format = "Memory: {used:0.1f}G / {total:0.1f}G ({percentage}%)";
        on-click = "ghostty -e btop";
      };

      "disk" = {
        interval = 30;
        format = "󰋊  {used} ({percentage_used}%)";
        path = "/";
        tooltip-format = "Disk: {used} / {total} ({percentage_used}%)";
        on-click = "ghostty -e btop";
      };

      "custom/uptime" = {
        exec = "${waybar-uptime}";
        interval = 60;
        format = "󰔟  {}";
        tooltip-format = "System uptime";
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
        interval = 5;
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
        format = "{icon}  {capacity}%";
        format-charging = "󰂄 {capacity}%";
        format-plugged = "󰂄 {capacity}%";
        format-alt = "{time} {icon}";
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
            "󰕿 "
            "󰖀 "
            "󰕾 "
          ];
        };
        on-click = "pamixer -t";
        on-click-right = "pavucontrol";
        scroll-step = 5;
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
        hide-on-ok = true;
        format = "✗ {nr_failed}";
        format-ok = "✓";
        system = true;
        user = true;
      };
    };

    "waybar/style.css".text =
      lib.optionalString useDms ''
        @import url("colors-matugen.css");
      ''
      + ''
        * {
          background-color: transparent;
          color: #cdd6f4;
          border: none;
          border-radius: 0;
          min-height: 0;
          font-family: Cantarell;
          font-size: 13px;
        }

        .modules-left {
          margin-left: 8px;
        }

        #workspaces {
          background-color: #1e1e2e;
          border-radius: 6px;
          padding: 1px 3px;
          margin: 0;
        }

        .modules-center {
          background-color: transparent;
          border-radius: 6px;
          padding: 0 2px;
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
          color: #1e1e2e;
          background: linear-gradient(135deg, #89dceb 0%, #658594 100%);
          transition: all 0.3s ease-in-out;
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
          background-color: #11111b;
          color: #cdd6f4;
          border-radius: 8px;
          font-weight: 600;
          min-width: 200px;
          border: 1px solid #585b70;
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
        #custom-media,
        #custom-uptime {
          min-width: 10px;
          margin: 0 2px;
          padding: 1px 6px;
          border-radius: 6px;
          background-color: #1e1e2e;
          color: #cdd6f4;
          font-weight: 500;
        }

        #network {
          background-color: #a6e3a1;
          color: #1e1e2e;
        }

        #network.disconnected {
          background-color: #c34043;
          color: #cdd6f4;
        }

        #pulseaudio {
          background-color: #ffa066;
          color: #1e1e2e;
        }

        #pulseaudio.muted {
          background-color: #6c7086;
          color: #cdd6f4;
        }

        #cpu {
          background-color: #89b4fa;
          color: #1e1e2e;
        }

        #memory {
          background-color: #cba6f7;
          color: #1e1e2e;
        }

        #disk {
          background-color: #f9e2af;
          color: #1e1e2e;
        }

        #custom-uptime {
          background-color: #89dceb;
          color: #1e1e2e;
        }

        #battery {
          background-color: #98bb6c;
          color: #1e1e2e;
        }

        #battery.warning {
          background-color: #e6c384;
          color: #1e1e2e;
        }

        #battery.critical {
          background-color: #c34043;
          color: #cdd6f4;
        }

        #idle_inhibitor {
          background-color: #e6c384;
          color: #1e1e2e;
        }

        #idle_inhibitor.activated {
          background-color: #98bb6c;
          color: #1e1e2e;
        }

        #privacy {
          background-color: #c34043;
          color: #cdd6f4;
        }

        #systemd-failed-units {
          background-color: #98bb6c;
          color: #1e1e2e;
        }

        #systemd-failed-units.degraded {
          background-color: #c34043;
          color: #cdd6f4;
        }

        #custom-expand-icon {
          margin-right: 4px;
          background-color: #585b70;
          color: #cdd6f4;
          padding: 2px 8px;
          border-radius: 8px;
        }

        #tray {
          background-color: #585b70;
          color: #cdd6f4;
        }

        #clock {
          background-color: #11111b;
          color: #cdd6f4;
          margin-right: 6px;
          border-radius: 6px;
          padding: 1px 6px;
          font-weight: 600;
        }

        tooltip {
          padding: 8px;
          background-color: #1e1e2e;
          border: 1px solid #585b70;
          border-radius: 6px;
          color: #cdd6f4;
        }

        /* Tray popup menu styling */
        menu {
          background-color: #1e1e2e;
          border: 1px solid #585b70;
          border-radius: 6px;
          padding: 4px;
          color: #cdd6f4;
        }

        menu > menuitem {
          background-color: transparent;
          color: #cdd6f4;
          padding: 4px 8px;
          border-radius: 4px;
        }

        menu > menuitem:hover {
          background-color: #585b70;
          color: #cdd6f4;
        }

        menu > menuitem:disabled {
          color: #6c7086;
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
