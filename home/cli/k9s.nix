{ config, pkgs, lib, inputs, ... }:

let
  unstable-pkgs = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  home.packages = [ unstable-pkgs.k9s ];

  xdg.configFile."k9s/views.yaml".text = ''
    views:
      v1/pods:
        columns:
          - NAME
          - CPU
          - MEM
          - STATUS
  '';

  # Skin file at ~/.config/k9s/skins/matugen.yaml is written by matugen
  # (see home/desktop/matugen.nix) and refreshed on every wallpaper change.
  xdg.configFile."k9s/config.yaml".text = ''
    k9s:
      ui:
        skin: matugen
  '';
}
