{ config, pkgs, lib, ... }:

{
  home.packages = [
    (pkgs.writeShellScriptBin "browser-default" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Launch Brave with default profile
      exec brave --new-window "$@"

      # Launch Firefox with the default profile (uncomment to use Firefox)
      # exec firefox -P default --new-window "$@"
    '')
  ];
}