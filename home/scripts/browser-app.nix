{
  config,
  pkgs,
  lib,
  ...
}:

{
  home.packages = [
    (pkgs.writeShellScriptBin "browser-app" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Usage:
      #   browser-app <url>                  # defaults to Personal profile
      #   browser-app <profile> <url>        # explicit profile (Personal/Work)
      if [[ $# -ge 2 ]]; then
        profile="$1"
        url="$2"
      else
        profile="Personal"
        url="$1"
      fi

      exec brave --profile-directory="$profile" --app="$url"
    '')
  ];
}
