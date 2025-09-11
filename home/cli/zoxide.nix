{ config, pkgs, lib, inputs, ... }:

{
  # Zoxide (smart cd command)
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
    enableZshIntegration = true;
  };
} 