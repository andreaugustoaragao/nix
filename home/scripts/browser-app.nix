{ config, pkgs, lib, ... }:

{
  home.packages = [
    (pkgs.writeShellScriptBin "browser-app" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Launch Brave with app mode
      exec brave --app="$@"

      # Launch Firefox with the app profile (uncomment to use Firefox)
      # exec firefox -P app --new-window "$@"
    '')
  ];
}