{ config, pkgs, lib, inputs, ... }:

{
  home.packages = [ pkgs.fastfetch pkgs.fortune pkgs.lolcat ];

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
} 