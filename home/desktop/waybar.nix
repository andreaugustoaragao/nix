{ config, pkgs, lib, inputs, ... }:

{
  # Status bar - Waybar (extracted from wayland.nix)
  programs.waybar = {
    enable = true;
    systemd.enable = true;
    settings = {
      mainBar = {
        reload_style_on_change = true;
        layer = "top";
        position = "top";
        spacing = 0;
        height = 26;
        margin-top = 8;
        modules-left = [ "niri/workspaces" "hyprland/workspaces" ];
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
            "1" = [];
            "2" = [];
            "3" = [];
            "4" = [];
            "5" = [];
          };
 
        };
        
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
          format-icons = ["󰤯" "󰤟" "󰤢" "󰤥" "󰤨"];
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
          format-icons = ["󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹"];
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
            default = ["󰕿" "󰖀" "󰕾"];
          };
          on-click = "pamixer -t";
          on-click-right = "pavucontrol";
          scroll-step = 5;
        };
        
        "group/tray-expander" = {
          orientation = "horizontal";
          modules = ["custom/expand-icon" "tray"];
          drawer = {
            transition-duration = 500;
            children-class = "tray-drawer";
            transition-left-to-right = true;
          };
        };
        
        "custom/expand-icon" = {
          format = " ";
          tooltip = false;
        };
        
        "tray" = {
          icon-size = 12;
          spacing = 12;
          show-passive-items = false;
        };
      };
    };
    
    style = ''
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
        background-color: #1f1f28;
        border-radius: 8px;
        padding: 2px 8px;
      }
      
      .modules-center {
        background-color: transparent;
        border-radius: 8px;
        padding: 2px 8px;
      }
      
      .modules-right {
        margin-right: 8px;
      }
      
      #workspaces button {
        all: initial;
        padding: 0 6px;
        margin: 0 1.5px;
        min-width: 9px;
        color: #dcd7ba;
      }
      
      #workspaces button.empty {
        opacity: 0.5;
      }
      
      #workspaces button.active {
        color: #dcd7ba;
      }
      
      #workspaces button.focused {
        color: #dcd7ba;
      }
      
      #workspaces button.urgent {
        color: #c34043;
      }
      
      #tray,
      #cpu,
      #battery,
      #memory,
      #disk,
      #network,
      #pulseaudio,
      #custom-media {
        min-width: 12px;
        margin: 0 7.5px;
        padding: 2px 8px;
        border-radius: 6px;
      }
      
      #network {
        background-color: #76946a;
        color: #1f1f28;
      }
      
      #pulseaudio {
        background-color: #ffa066;
        color: #1f1f28;
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
      
      #network.disconnected {
        background-color: #c34043;
        color: #dcd7ba;
      }
      
      #pulseaudio.muted {
        background-color: #727169;
        color: #dcd7ba;
      }
      
      #custom-expand-icon {
        margin-right: 7px;
        color: #dcd7ba;
        background-color: #54546d;
        padding: 2px 8px;
        border-radius: 6px;
      }
      
      #tray {
        background-color: #54546d;
        color: #dcd7ba;
      }
      
      #clock {
        background-color: #7fb4ca;
        color: #1f1f28;
        margin-right: 8px;
        border-radius: 6px;
        padding: 2px 8px;
      }
      
      tooltip {
        padding: 8px;
        background-color: #1f1f28;
        border: 1px solid #54546d;
        border-radius: 6px;
        color: #dcd7ba;
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


