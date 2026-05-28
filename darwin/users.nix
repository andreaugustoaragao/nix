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
    inherit (owner) name;
    home = "${homePrefix}/${owner.name}";
    shell = pkgs.fish;
  };

  # Register fish as the system login shell. `programs.fish.enable`
  # adds the binary to /etc/shells (macOS refuses to use unlisted
  # shells via `chsh` / loginwindow) and wires nix-darwin's vendor
  # functions/completions into XDG_DATA_DIRS so home-manager's
  # programs.fish picks them up.
  programs.fish.enable = true;

  # zsh stays enabled so /etc/zshrc still sources the nix profile
  # PATH — useful when a brew cask or installer pkg invokes `sh -c
  # 'zsh -i …'` during its postinstall script.
  programs.zsh.enable = true;
}
