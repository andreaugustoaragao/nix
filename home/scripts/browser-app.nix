{ config, pkgs, lib, ... }:

{
  home.packages = [
    (pkgs.writeShellScriptBin "browser-app" ''
      #!/usr/bin/env bash
      set -euo pipefail
      
      # Launch Firefox with the app profile
      exec firefox -P app --new-window "$@"
    '')
  ];
}