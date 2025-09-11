{ config, pkgs, lib, inputs, ... }:

{
  services.kmscon = {
    enable = true;
    hwRender = true;
    fonts = [{ name = "JetBrains Mono"; package = pkgs.jetbrains-mono; }];
    extraConfig = ''
      font-size=12
      xkb-layout=us
    '';
  };
} 