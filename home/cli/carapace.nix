{
  pkgs,
  lib,
  ...
}:
let
  # Pre-generate the static fish completion script at build time instead of
  # spawning `carapace _carapace fish | source` (~80 ms) on every shell launch.
  # Strip the build-time `fish_add_path` line so sandbox $HOME never leaks.
  carapaceFishInit = pkgs.runCommand "carapace-init.fish" { } ''
    HOME="$TMPDIR" ${pkgs.carapace}/bin/carapace _carapace fish \
      | ${pkgs.gnused}/bin/sed '/^fish_add_path /d' > "$out"
  '';
in
{
  # Multi-shell completion engine — knows ~1200 CLIs out of the box
  # (kubectl, gh, helm, gcloud, databricks, terraform, etc.). Falls
  # back to fish/zsh native completions for tools it doesn't cover.
  programs.carapace = {
    enable = true;
    enableFishIntegration = false;
    enableZshIntegration = true;
  };

  programs.fish.interactiveShellInit = lib.mkAfter ''
    source ${carapaceFishInit}
  '';
}
