{
  config,
  pkgs,
  lib,
  ...
}:

let
  payRespectsZshInit = pkgs.runCommand "pay-respects-init.zsh" { } ''
    HOME="$TMPDIR" ${pkgs.pay-respects}/bin/pay-respects zsh --alias > "$out"
  '';
in
{
  # Auto-correct mistyped commands. After a failed command, type `f`
  # and press Enter to apply pay-respects' suggested fix (missing
  # sudo, typoed git subcommand, etc.).
  programs.pay-respects = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = false;
  };

  programs.zsh.initContent = lib.mkIf config.programs.zsh.enable (
    lib.mkAfter ''
      source ${payRespectsZshInit}
    ''
  );
}
