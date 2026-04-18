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
          - STATUS
          - CPU
          - MEM
  '';
}
