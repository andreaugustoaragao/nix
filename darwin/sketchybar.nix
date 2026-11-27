{ pkgs, ... }:

{
  # SketchyBar status bar daemon (macOS replacement for the auto-hidden
  # global menu bar, paired with AeroSpace workspaces).
  #
  # Leave `config` empty so Home Manager (`home/cli/sketchybar.nix`) owns
  # `~/.config/sketchybar/sketchybarrc` and all theme-aware plugins.
  services.sketchybar = {
    enable = true;
    extraPackages = [
      pkgs.gawk
    ];
  };
}
