{ config, pkgs, lib, inputs, ... }:

{
  home.packages = lib.optionals (config.wayland.windowManager.hyprland.enable || config.programs.niri.enable) [
    pkgs.wl-clipboard  # Provides wl-copy and wl-paste for clipboard operations
    (pkgs.writeShellScriptBin "screenshot" ''
      # Omarchy-style screenshot script for NixOS (Wayland-only)
      [[ -f ~/.config/user-dirs.dirs ]] && source ~/.config/user-dirs.dirs
      PICTURES_DIR="''${XDG_PICTURES_DIR:-$HOME/pictures}"
      OUTPUT_DIR=""$PICTURES_DIR"/screenshots"

      ${pkgs.coreutils}/bin/mkdir -p "$OUTPUT_DIR"
      ${pkgs.procps}/bin/pkill slurp || true

      MODE="''${1:-region}"
      if [ "$MODE" = "monitor" ]; then
        MODE="output"
      fi

      ACTIVE_ARG=""
      if [ "$MODE" = "output" ]; then
        ACTIVE_ARG="-m active"
      fi

      ${pkgs.hyprshot}/bin/hyprshot -m "$MODE" $ACTIVE_ARG --raw | \
        ${pkgs.satty}/bin/satty --filename - \
          --output-filename "$OUTPUT_DIR/screenshot-$(${pkgs.coreutils}/bin/date +'%Y-%m-%d_%H-%M-%S').png" \
          --early-exit \
          --copy-command '${pkgs.wl-clipboard}/bin/wl-copy'
    '')
  ];
} 