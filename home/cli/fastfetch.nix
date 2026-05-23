{
  pkgs,
  inputs,
  wallpapers,
  ...
}:

let
  # Kameido Plum Park — ukiyo-e with scroll cartouches; light mode on the
  # physically left monitor (DP-2). See home/desktop/niri.nix output layout.
  fastfetchLogo = "${wallpapers}/share/wallpapers/kameido-plum-park.jpg";
  logoWidth = 38;
  # Portrait ~2041×3000; terminal cells are ~2× taller than wide.
  logoHeight = (logoWidth * 3000 + 2041) / (2 * 2041);
in
{
  home.packages = [
    inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.fastfetch
    pkgs.chafa
    pkgs.fortune
    pkgs.lolcat
  ];

  # Fastfetch configuration (Omarchy style adapted for NixOS)
  xdg.configFile."fastfetch/config.jsonc".text = ''
    {
      "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
      "logo": {
        "type": "auto",
        "source": "${fastfetchLogo}",
        "width": ${toString logoWidth},
        "height": ${toString logoHeight},
        "padding": {
          "top": 1,
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
        {
          "type": "shell",
          "key": "󱆃 Shell",
          "keyColor": "blue"
        },
        {
          "type": "editor",
          "key": "󰲹 Editor",
          "keyColor": "blue"
        },
        {
          "type": "locale",
          "key": "󰖷 Locale",
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
          "text": "birth_install=$(stat -c %W / 2>/dev/null || stat -f %B /); current=$(date +%s); time_progression=$((current - birth_install)); days_difference=$((time_progression / 86400)); echo $days_difference days"
        },
        {
          "type": "uptime",
          "key": "󰔛 Uptime",
          "keyColor": "magenta"
        },
        {
          "type": "loadavg",
          "key": "󰔡 Load",
          "keyColor": "magenta"
        },
        {
          "type": "processes",
          "key": "󰙨 Procs",
          "keyColor": "magenta"
        },
        {
          "type": "datetime",
          "key": "󰃰 Date",
          "keyColor": "magenta",
          "format": "{year}-{month-pretty}-{day-pretty} {hour-pretty}:{minute-pretty}"
        },
        "break",
        {
          "type": "colors",
          "paddingLeft": 2,
          "symbol": "block"
        },
        "break"
      ]
    }
  '';
}
