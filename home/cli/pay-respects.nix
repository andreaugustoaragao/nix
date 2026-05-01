{ ... }:

{
  # Auto-correct mistyped commands. After a failed command, type `f`
  # and press Enter to apply pay-respects' suggested fix (missing
  # sudo, typoed git subcommand, etc.).
  programs.pay-respects = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };
}
