{
  lib,
  pkgs,
  ...
}:

let
  skill = builtins.path {
    name = "email-send-skill";
    path = ./email-send;
  };
  emailSendPkg = pkgs.callPackage ../../pkgs/email-send.nix {
    browser-task = pkgs.callPackage ../../pkgs/browser-task.nix { };
  };
  roots = [
    ".agents/skills"
    ".cursor/skills"
  ];
in
{
  home.packages = [
    emailSendPkg
  ];
  home.file = lib.genAttrs (map (root: "${root}/email-send") roots) (_: {
    source = skill;
  });
}
