{ config, pkgs, lib, inputs, ... }:
let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  # Install ghostty from unstable packages
  home.packages = [ pkgs-unstable.ghostty ];
  xdg.configFile."ghostty/config".text = ''
    # Font configuration
    font-family = CaskaydiaMono Nerd Font
    font-size = 11
    
    # Shell configuration
    shell-integration = fish
    command = fish
    
    # Window configuration
    window-padding-x = 14
    window-padding-y = 14
    window-theme = dark
    
    # Kanagawa color scheme
    background = 1f1f28
    foreground = dcd7ba
    
    # Cursor colors
    cursor-color = dcd7ba
    cursor-text = 1f1f28
    
    # Selection colors
    selection-background = 2d4f67
    selection-foreground = dcd7ba
    
    # Kanagawa color palette
    palette = 0=#090618
    palette = 1=#c34043
    palette = 2=#76946a
    palette = 3=#c0a36e
    palette = 4=#7e9cd8
    palette = 5=#957fb8
    palette = 6=#6a9589
    palette = 7=#c8c093
    palette = 8=#727169
    palette = 9=#e82424
    palette = 10=#98bb6c
    palette = 11=#e6c384
    palette = 12=#7fb4ca
    palette = 13=#938aa9
    palette = 14=#7aa89f
    palette = 15=#dcd7ba
    
    # Additional settings
    window-decoration = false
    unfocused-split-opacity = 0.9
    copy-on-select = false
  '';
} 