{ config, pkgs, lib, inputs, owner, ... }:

{
  users.users.${owner.name} = {
    isNormalUser = true;
    description = owner.fullName;
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
      # Allow ${owner.name} to run nixos-rebuild without password for auto-rebuild service
      ${owner.name} ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/nixos-rebuild
    '';
  };
} 