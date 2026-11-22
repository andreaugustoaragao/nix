{ unstable-pkgs, ... }:

let
  graphify = unstable-pkgs.callPackage ../../pkgs/graphify.nix { };
in
{
  home.packages = [ graphify ];

  home.file.".agents/skills/graphify".source = ./graphify;
}
