{ config, pkgs, lib, inputs, ... }:

{
  services.kmscon = {
    enable = true;
    fonts = [
      {
        name = "CaskaydiaMono Nerd Font Mono";
        package = pkgs.nerd-fonts.caskaydia-mono;
      }
    ];
    extraOptions = ''
    '';
    hwRender = false;  # Disable hardware rendering to avoid DRM conflicts with X server
    extraConfig = ''
      font-size=12
      font-dpi=144
    '';
  };
} 