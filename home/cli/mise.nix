_:

{
  # Polyglot runtime version manager (replaces nvm/pyenv/asdf/goenv).
  # Reads .mise.toml or .tool-versions per directory and activates the
  # matching versions on cd. Works with direnv too.
  programs.mise = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };
}
