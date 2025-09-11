{ config, pkgs, lib, inputs, ... }:

{
  # Greetd configuration with auto-login
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = "${pkgs.niri}/bin/niri-session";
        user = "aragao";
      };
    };
  };

  services.gnome.gnome-keyring.enable = true;
  security.polkit.enable = true;
  # Update PAM services for greetd
  security.pam.services.greetd.enableGnomeKeyring = true;
} 