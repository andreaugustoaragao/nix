{
  config,
  lib,
  pkgs,
  ...
}:

let
  skill = builtins.path {
    name = "chat-send-skill";
    path = ./chat-send;
  };
  chatSend = pkgs.writeShellApplication {
    name = "chat-send";
    runtimeInputs = [
      pkgs.python3
      (pkgs.callPackage ../../pkgs/browser-task.nix { })
    ];
    text = ''
      exec python3 ${skill}/scripts/chat_send.py "$@"
    '';
  };
  roots = [
    ".agents/skills"
    "${lib.removePrefix "${config.home.homeDirectory}/" config.xdg.configHome}/opencode/skills"
  ];
in
{
  home.packages = [ chatSend ];
  home.file = lib.genAttrs (map (root: "${root}/chat-send") roots) (_: {
    source = skill;
  });
}
