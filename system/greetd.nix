{ config, pkgs, lib, inputs, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.system;
    config.allowUnfree = true;
  };
in
{
  # Greetd configuration with auto-login
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs-unstable.niri}/bin/niri-session";
        user = "aragao";
      };
    };
  };

  services.gnome.gnome-keyring.enable = true;
  security.polkit.enable = true;
  # Update PAM services for greetd
  security.pam.services.greetd.enableGnomeKeyring = true;
} 