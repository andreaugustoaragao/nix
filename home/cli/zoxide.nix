_:

{
  # Default integrations add a `z` command without touching `cd`. We
  # disable fish here and re-init it manually in fish.nix with
  # `--cmd cd` so only fish gets the cd-replacement; zsh/bash (used by
  # CLI agents and scripts) keep POSIX cd intact.
  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
    enableFishIntegration = false;
    enableZshIntegration = true;
  };
}
