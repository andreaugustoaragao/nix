{
  pkgs,
  ...
}:

{
  home.packages = [
    (pkgs.writeShellScriptBin "browser-default" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Usage:
      #   browser-default                    # new tab, Personal profile
      #   browser-default <url>              # tab at url, Personal profile
      #   browser-default <profile> <url>    # explicit profile (Personal/Work)
      if [[ $# -ge 2 ]]; then
        profile="$1"
        url="$2"
        exec brave --profile-directory="$profile" "$url"
      elif [[ $# -eq 1 ]]; then
        exec brave --profile-directory=Personal "$1"
      else
        exec brave --profile-directory=Personal brave://newtab/
      fi
    '')
  ];
}
