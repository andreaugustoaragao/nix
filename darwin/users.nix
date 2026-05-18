{
  pkgs,
  owner,
  homePrefix,
  ...
}:

{
  # nix-darwin does NOT create the user account — macOS handles that
  # via System Settings / `dscl`. This block only tells nix-darwin
  # which existing account is "ours" so home-manager can write into
  # the right home directory and shell/path defaults apply.
  users.users.${owner.name} = {
    name = owner.name;
    home = "${homePrefix}/${owner.name}";
    shell = pkgs.zsh;
  };

  # Make zsh the system default and let nix-darwin manage its rc bits
  # so /etc/zshrc sources /nix-installed completions and PATH.
  programs.zsh.enable = true;
}
