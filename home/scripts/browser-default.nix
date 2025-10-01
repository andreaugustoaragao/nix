{ config, pkgs, lib, ... }:

{
  home.packages = [
    (pkgs.writeShellScriptBin "browser-default" ''
      #!/usr/bin/env bash
      set -euo pipefail
      
      # Launch Firefox with the default profile
      exec firefox -P default --new-window "$@"
    '')
  ];
}