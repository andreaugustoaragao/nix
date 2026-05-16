_:

{
  # Multi-shell completion engine — knows ~1200 CLIs out of the box
  # (kubectl, gh, helm, gcloud, databricks, terraform, etc.). Falls
  # back to fish/zsh native completions for tools it doesn't cover.
  programs.carapace = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };
}
