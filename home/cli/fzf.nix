{ ... }:

{
  # Point fzf at the matugen-rendered options file so its colors follow
  # the wallpaper palette. The file itself is written by matugen — see
  # home/desktop/matugen.nix [templates.fzf]. fzf reads it on every
  # invocation, so no live-reload signal is needed.
  home.sessionVariables.FZF_DEFAULT_OPTS_FILE = "$HOME/.config/fzf/opts.conf";
}
