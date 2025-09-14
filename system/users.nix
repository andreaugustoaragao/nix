{ config, pkgs, lib, inputs, ... }:

{
  users.users.aragao = {
    isNormalUser = true;
    description = "Andre Aragao";
    extraGroups = [ "wheel" "audio" "video" "docker" "input" ];
    shell = pkgs.zsh;
  };

  programs.zsh.enable = true;
  programs.command-not-found.enable = false;
  programs.nix-index = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
    enableFishIntegration = true;
  };

  security.sudo = {
    enable = true;
    extraConfig = ''
      Defaults timestamp_timeout=60
      # Allow aragao to run nixos-rebuild without password for auto-rebuild service
      aragao ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/nixos-rebuild
    '';
  };
} 