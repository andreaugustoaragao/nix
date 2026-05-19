_:

{
  # Replace `cd` with zoxide across all shells. The Home Manager
  # module emits the init line into each shell's interactive config,
  # so no per-shell shell-out from fish.nix is needed.
  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
    options = [ "--cmd cd" ];
  };
}
