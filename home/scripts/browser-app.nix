{
  pkgs,
  ...
}:

{
  home.packages = [
    (pkgs.writeShellScriptBin "browser-app" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Usage:
      #   browser-app [--class=CLASS] <url>            # defaults to Personal profile
      #   browser-app [--class=CLASS] <profile> <url>  # explicit profile (Personal/Work)
      #
      # --class sets Brave's Wayland app_id (and X11 WM_CLASS). Without it,
      # `--app=<url>` windows get an auto-generated app_id like
      # `brave-meet.google.com__-Default`, which has no matching desktop
      # entry — so the bar/taskbar shows that raw id instead of a friendly
      # name. Passing a stable class that a .desktop entry's StartupWMClass
      # matches lets the shell resolve it to the app's display name + icon.
      class=""
      if [[ "''${1:-}" == --class=* ]]; then
        class="''${1#--class=}"
        shift
      fi

      if [[ $# -ge 2 ]]; then
        profile="$1"
        url="$2"
      else
        profile="Personal"
        url="$1"
      fi

      args=(--profile-directory="$profile" --app="$url")
      [[ -n "$class" ]] && args+=(--class="$class")
      exec brave "''${args[@]}"
    '')
  ];
}
