{ ... }:

{
  # Tokyo Night Storm palette via FZF_DEFAULT_OPTS. fzf reads it on every
  # invocation — no live-reload needed.
  home.sessionVariables.FZF_DEFAULT_OPTS = builtins.concatStringsSep "," [
    "--color=fg:#a9b1d6"
    "bg:-1"
    "hl:#7aa2f7"
    "fg+:#c0caf5"
    "bg+:#3d59a1"
    "hl+:#7dcfff"
    "info:#bb9af7"
    "prompt:#7dcfff"
    "pointer:#f7768e"
    "marker:#9ece6a"
    "spinner:#bb9af7"
    "header:#565f89"
    "border:#414868"
  ];
}
