{
  pkgs,
  inputs,
  ...
}:

{
  home.packages = [
    inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.fastfetch
    pkgs.fortune
    pkgs.lolcat
  ];

  # Fastfetch configuration (Omarchy style adapted for NixOS)
  xdg.configFile."fastfetch/config.jsonc".text = ''
    {
      "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
      "logo": {
        "type": "builtin",
        "source": "nixos",
        "color": { "1": "magenta" },
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
          "format": "\u001b[90m──────────── Hardware ────────────"
        },
        {
          "type": "host",
          "key": "󰟀 PC",
          "keyColor": "green"
        },
        {
          "type": "cpu",
          "key": "󰍛 CPU",
          "showPeCoreCount": true,
          "keyColor": "green"
        },
        {
          "type": "gpu",
          "key": "󰢮 GPU",
          "detectionMethod": "pci",
          "keyColor": "green"
        },
        {
          "type": "display",
          "key": "󰍹 Display",
          "keyColor": "green"
        },
        {
          "type": "disk",
          "key": "󰋊 Disk",
          "keyColor": "green"
        },
        {
          "type": "memory",
          "key": "󰑭 Memory",
          "keyColor": "green"
        },
        {
          "type": "swap",
          "key": "󰾵 Swap",
          "keyColor": "green"
        },
        "break",
        {
          "type": "custom",
          "format": "\u001b[90m──────────── Software ────────────"
        },
        {
          "type": "os",
          "key": "󰣇 OS",
          "keyColor": "blue"
        },
        {
          "type": "kernel",
          "key": "󰌽 Kernel",
          "keyColor": "blue"
        },
        {
          "type": "wm",
          "key": "󰨇 WM",
          "keyColor": "blue"
        },
        {
          "type": "de",
          "key": "󰧨 DE",
          "keyColor": "blue"
        },
        {
          "type": "terminal",
          "key": "󰆍 Terminal",
          "keyColor": "blue"
        },
        {
          "type": "wmtheme",
          "key": "󰉼 Theme",
          "keyColor": "blue"
        },
        {
          "type": "custom",
          "key": "󰸌 Icons",
          "keyColor": "blue",
          "format": "Catppuccin Mocha"
        },
        {
          "type": "terminalfont",
          "key": "󰛖 Font",
          "keyColor": "blue"
        },
         "break",
        {
          "type": "custom",
          "format": "\u001b[90m──────────── Status ────────────"
        },
        {
          "type": "command",
          "key": "󰅐 OS Age",
          "keyColor": "magenta",
          "text": "birth_install=$(stat -c %W /); current=$(date +%s); time_progression=$((current - birth_install)); days_difference=$((time_progression / 86400)); echo $days_difference days"
        },
        {
          "type": "uptime",
          "key": "󰔛 Uptime",
          "keyColor": "magenta"
        },
        "break"
      ]
    }
  '';
}
