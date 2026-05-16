_:

{
  # Catppuccin Mocha palette via FZF_DEFAULT_OPTS. fzf reads it on every
  # invocation — no live-reload needed.
  home.sessionVariables.FZF_DEFAULT_OPTS = builtins.concatStringsSep "," [
    "--color=fg:#bac2de"
    "bg:-1"
    "hl:#89b4fa"
    "fg+:#cdd6f4"
    "bg+:#313244"
    "hl+:#94e2d5"
    "info:#cba6f7"
    "prompt:#94e2d5"
    "pointer:#f38ba8"
    "marker:#a6e3a1"
    "spinner:#cba6f7"
    "header:#6c7086"
    "border:#585b70"
  ];
}
