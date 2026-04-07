{ config, pkgs, lib, inputs, owner, autoLogin, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  # Greetd configuration with conditional auto-login
  services.greetd = {
    enable = true;
    settings = if autoLogin then {
      # Auto-login configuration - goes straight to desktop
      default_session = {
        command = "${pkgs-unstable.niri}/bin/niri-session";
        # command = "${pkgs.hyprland}/bin/Hyprland";
        user = owner.name;
      };
    } else {
      # Interactive login configuration - shows login prompt
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd ${pkgs-unstable.niri}/bin/niri-session";
        user = "greeter";
      };
    };
  };

  services.gnome.gnome-keyring.enable = true;

  security.polkit.enable = true;
  
  # Update PAM services for greetd
  security.pam.services.greetd.enableGnomeKeyring = true;
} 