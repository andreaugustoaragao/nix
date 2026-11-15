{ lib, pkgs, ... }:
let
  agents = pkgs.callPackage ../../pkgs/agent-binaries { };
in
{
  home.packages = [
    agents.codex
    agents.pi
    agents.cursor-agent
  ];
  home.file =
    lib.mapAttrs
      (_: source: {
        inherit source;
        force = true;
      })
      {
        ".local/bin/pi" = "${agents.pi}/bin/pi";
        ".local/bin/cursor-agent" = "${agents.cursor-agent}/bin/cursor-agent";
        ".local/bin/agent" = "${agents.cursor-agent}/bin/agent";
      };
}
