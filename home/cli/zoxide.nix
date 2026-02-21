{ config, pkgs, lib, inputs, ... }:

{
  # Zoxide (smart cd command)
  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };
} 