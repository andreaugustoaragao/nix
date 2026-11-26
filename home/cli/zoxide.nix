{
  config,
  pkgs,
  lib,
  ...
}:

let
  zoxideZshInit = pkgs.runCommand "zoxide-init.zsh" { } ''
    ${pkgs.zoxide}/bin/zoxide init zsh --cmd cd > "$out"
  '';
in
{
  # Replace `cd` with zoxide across all shells. Zsh sources a build-time
  # static init script to avoid forking `zoxide init` on every shell launch.
  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
    enableFishIntegration = true;
    enableZshIntegration = false;
    options = [ "--cmd cd" ];
  };

  programs.zsh.initContent = lib.mkIf config.programs.zsh.enable (
    lib.mkAfter ''
      source ${zoxideZshInit}
    ''
  );

  # Keep zoxide's doctor quiet if downstream tooling wraps `cd` later.
  home.sessionVariables._ZO_DOCTOR = "0";
}
