{
  config,
  pkgs,
  lib,
  ...
}:

{
  home.packages = [
    (pkgs.writeShellScriptBin "browser-default" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Usage:
      #   browser-default                    # new window, Personal profile
      #   browser-default <url>              # new window at url, Personal profile
      #   browser-default <profile> <url>    # explicit profile (Personal/Work)
      if [[ $# -ge 2 ]]; then
        profile="$1"
        url="$2"
        exec brave --profile-directory="$profile" --new-window "$url"
      elif [[ $# -eq 1 ]]; then
        exec brave --profile-directory=Personal --new-window "$1"
      else
        exec brave --profile-directory=Personal --new-window
      fi
    '')
  ];
}
