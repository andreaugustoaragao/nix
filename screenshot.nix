{ pkgs }:

pkgs.writeShellScriptBin "screenshot" ''
  # Omarchy-style screenshot script for NixOS
  # Based on /home/aragao/omarchy/bin/omarchy-cmd-screenshot

  [[ -f ~/.config/user-dirs.dirs ]] && source ~/.config/user-dirs.dirs
  OUTPUT_DIR="''${XDG_PICTURES_DIR:-$HOME/pictures}"

  if [[ ! -d "$OUTPUT_DIR" ]]; then
    ${pkgs.libnotify}/bin/notify-send "Screenshot directory does not exist: $OUTPUT_DIR" -u critical -t 3000
    exit 1
  fi

  # Kill any existing slurp processes before starting
  ${pkgs.procps}/bin/pkill slurp || true

  # Take screenshot with hyprshot and pipe to satty for editing
  ${pkgs.hyprshot}/bin/hyprshot -m ''${1:-region} --raw | \
    ${pkgs.satty}/bin/satty --filename - \
      --output-filename "$OUTPUT_DIR/screenshot-$(${pkgs.coreutils}/bin/date +'%Y-%m-%d_%H-%M-%S').png" \
      --early-exit \
      --copy-command '${pkgs.wl-clipboard}/bin/wl-copy'
''
