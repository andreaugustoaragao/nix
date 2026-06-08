{
  pkgs,
  owner,
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
      "docker"
      "input"
      "lp"
      "scanner"
    ];
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
    extraConfig = ''
      Defaults timestamp_timeout=60
      # Passwordless nixos-rebuild is required by scripts/watch-rebuild.sh,
      # which runs `sudo --non-interactive nixos-rebuild` in its edit loop and
      # would hard-fail once the 60-minute sudo timestamp expires. Security
      # trade-off, eyes open: a user-controlled `--flake` here is effectively
      # passwordless root. The tighter fix — a root oneshot pinned to THIS
      # flake path plus a narrow `systemctl start` grant, so the loop keeps
      # working without granting arbitrary-flake root — is left as a follow-up.
      ${owner.name} ALL=(ALL) NOPASSWD: /run/current-system/sw/bin/nixos-rebuild
      # (The previously-present k3s image NOPASSWD rule was unused; dropped.)
    '';
  };
}
