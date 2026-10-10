{
  pkgs,
  lib,
  owner,
  hostName,
  ...
}:

{
  users.users.${owner.name} = {
    isNormalUser = true;
    description = owner.fullName;
    extraGroups = [
      "wheel"
      "audio"
      "video"
      "input"
      "lp"
      "scanner"
    ]
    ++ lib.optional (hostName != "prl-dev-vm") "docker";
    shell = pkgs.zsh;
  };

  programs = {
    zsh.enable = true;
    command-not-found.enable = false;
    nix-index = {
      enable = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
      enableFishIntegration = true;
    };
    nix-index-database.comma.enable = true;
  };

  security.sudo = {
    enable = true;
    extraConfig =
      if hostName == "prl-dev-vm" then
        ''
          # Automatic builds run unprivileged. Activation requires sudo
          # authentication, even when the flake path is fixed.
          Defaults timestamp_timeout=5
        ''
      else
        ''
          Defaults timestamp_timeout=60
          # Other hosts retain their existing policy until migrated.
          ${owner.name} ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/nixos-rebuild
        '';
  };
}
