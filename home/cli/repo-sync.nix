{
  config,
  lib,
  pkgs,
  ...
}:

let
  skill = builtins.path {
    name = "repo-sync-skill";
    path = ./repo-sync;
  };
  repoSync = pkgs.writeShellApplication {
    name = "repo-sync";
    runtimeInputs = [
      pkgs.python3
      pkgs.git
    ];
    text = ''
      exec python3 ${skill}/scripts/repo-sync.py "$@"
    '';
  };
  roots = [
    ".agents/skills"
    "${lib.removePrefix "${config.home.homeDirectory}/" config.xdg.configHome}/opencode/skills"
  ];
in
{
  home.packages = [ repoSync ];
  home.file = lib.genAttrs (map (root: "${root}/repo-sync") roots) (_: {
    source = skill;
  });
}
