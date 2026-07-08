{ pkgs, ... }:

{
  # System-wide packages that should exist for every user on the box.
  # Keep this list lean — anything user-specific belongs in home/.
  environment.systemPackages = with pkgs; [
    claude-code
    vim
    git
    curl
    wget
    age
    sops
    htop
    tree
    nixfmt
  ];
}
