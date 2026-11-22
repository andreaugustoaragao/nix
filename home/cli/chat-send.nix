{
  lib,
  pkgs,
  ...
}:

let
  skill = builtins.path {
    name = "chat-send-skill";
    path = ./chat-send;
  };
  chatSendPkg = pkgs.callPackage ../../pkgs/chat-send.nix {
    browser-task = pkgs.callPackage ../../pkgs/browser-task.nix { };
    workerExtension = "${skill}/scripts/worker.ts";
  };
  roots = [
    ".agents/skills"
  ];
in
{
  home.packages = [
    chatSendPkg
  ];
  home.file = lib.genAttrs (map (root: "${root}/chat-send") roots) (_: {
    source = skill;
  });
}
