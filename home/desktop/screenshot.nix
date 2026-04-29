{ config, osConfig, pkgs, lib, inputs, ... }:

let
  niriEnabled = osConfig.programs.niri.enable or false;
in
{
  home.packages =
    lib.optionals (config.wayland.windowManager.hyprland.enable || niriEnabled) [
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
    ]
    ++ lib.optionals niriEnabled [
      # niri-native variant: capture comes from niri's IPC (`niri msg
      # action screenshot{,-screen,-window}`) so window bounds and
      # niri's own render effects (DMS panels, etc.) are honoured. The
      # interactive `ui` mode shows niri's overlay (Space cycles
      # region/output/window selection). Annotation still goes through
      # satty — coexists with `screenshot` rather than replacing it.
      (pkgs.writeShellScriptBin "screenshot-niri" ''
        set -euo pipefail

        [[ -f ~/.config/user-dirs.dirs ]] && source ~/.config/user-dirs.dirs
        PICTURES_DIR="''${XDG_PICTURES_DIR:-$HOME/pictures}"
        OUTPUT_DIR="$PICTURES_DIR/screenshots"
        ${pkgs.coreutils}/bin/mkdir -p "$OUTPUT_DIR"
        OUTFILE="$OUTPUT_DIR/screenshot-$(${pkgs.coreutils}/bin/date +%Y-%m-%d_%H-%M-%S).png"

        MODE="''${1:-ui}"
        TMPDIR=$(${pkgs.coreutils}/bin/mktemp -d -t niri-screenshot.XXXXXX)
        trap '${pkgs.coreutils}/bin/rm -rf "$TMPDIR"' EXIT
        TMP="$TMPDIR/raw.png"

        case "$MODE" in
          -h|--help)
            echo "Usage: screenshot-niri [MODE]"
            echo
            echo "  ui (default)  niri's interactive overlay (Space cycles"
            echo "                region/output/window, Enter accepts, Esc cancels)."
            echo "  output        focused output, no UI."
            echo "  window        focused window, no UI."
            exit 0
            ;;
          ui|region)
            # niri's interactive action returns before the user finishes
            # selecting, so poll up to 5 min for the temp file to land
            # and stop growing. Esc/cancel → never written → time out.
            niri msg action screenshot --path "$TMP"
            last=-1
            for _ in $(${pkgs.coreutils}/bin/seq 1 3000); do
              if [[ -s "$TMP" ]]; then
                sz=$(${pkgs.coreutils}/bin/stat -c %s "$TMP")
                [[ "$sz" -eq "$last" ]] && break
                last=$sz
              fi
              ${pkgs.coreutils}/bin/sleep 0.1
            done
            ;;
          output|monitor)
            niri msg action screenshot-screen --path "$TMP"
            ;;
          window)
            niri msg action screenshot-window --path "$TMP"
            ;;
          *)
            echo "screenshot-niri: unknown mode '$MODE' (use ui, output, or window)" >&2
            exit 1
            ;;
        esac

        if [[ ! -s "$TMP" ]]; then
          echo "screenshot-niri: cancelled or timed out" >&2
          exit 1
        fi

        ${pkgs.satty}/bin/satty --filename "$TMP" \
          --output-filename "$OUTFILE" \
          --early-exit \
          --copy-command '${pkgs.wl-clipboard}/bin/wl-copy'
      '')
    ];
} 