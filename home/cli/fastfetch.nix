{
  pkgs,
  unstable-pkgs,
  # wallpapers is exposed via _module.args by home/desktop/wallpapers.nix,
  # which is only loaded on graphical hosts. On tala (server) and mac-work
  # (darwin), the desktop module is skipped, so wallpapers is absent —
  # fall back to stock fastfetch (built-in distro logo) on those hosts.
  wallpapers ? null,
  ...
}:

let
  fastfetchPkg = unstable-pkgs.fastfetch;

  # Logos to rotate through on each invocation. Each entry carries its
  # own width/height so portrait and landscape sources render at the
  # right aspect ratio — terminal cells are roughly 2× taller than wide.
  logos = [
    {
      # Kameido Plum Park — portrait ukiyo-e (~2041×3000).
      path = "${wallpapers}/share/wallpapers/kameido-plum-park.jpg";
      width = 38;
      height = 28;
    }
    {
      # Avaya HQ — landscape photo (1168×880).
      path = "${wallpapers}/share/wallpapers/avaya-hq.png";
      width = 50;
      height = 19;
    }
  ];

  logoEntries = builtins.concatStringsSep "\n    " (
    map (l: "'${l.path}|${toString l.width}|${toString l.height}'") logos
  );

  # Wrapper exposed as `fastfetch` on PATH. Picks one logo at random per
  # invocation, then exec's the real fastfetch with --logo / --logo-width
  # / --logo-height set accordingly. Trailing "$@" lets ad-hoc CLI flags
  # still flow through; a user-supplied --logo later in argv wins because
  # fastfetch takes the last occurrence.
  fastfetchWrapper = pkgs.writeShellScriptBin "fastfetch" ''
    LOGOS=(
      ${logoEntries}
    )
    IFS='|' read -r logo_path logo_width logo_height <<<"''${LOGOS[$((RANDOM % ''${#LOGOS[@]}))]}"
    exec ${fastfetchPkg}/bin/fastfetch \
      --logo "$logo_path" \
      --logo-width "$logo_width" \
      --logo-height "$logo_height" \
      "$@"
  '';
in
{
  home.packages = [
    (if wallpapers != null then fastfetchWrapper else fastfetchPkg)
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
