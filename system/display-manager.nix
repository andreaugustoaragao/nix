{ config, pkgs, lib, inputs, owner, autoLogin, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.system;
    config.allowUnfree = true;
  };
in
{
  # Display manager configuration based on autoLogin setting
  services = lib.mkMerge [
    # Common services
    {
      gnome.gnome-keyring.enable = true;
    }
    
    # Conditional display manager services
    (if autoLogin then {
      # Auto-login configuration using greetd - goes straight to desktop
      greetd = {
        enable = true;
        settings = {
          default_session = {
            command = "${pkgs-unstable.niri}/bin/niri-session";
            # command = "${pkgs.hyprland}/bin/Hyprland";
            user = owner.name;
          };
        };
      };
    } else {
      # Interactive login configuration using LightDM
      xserver = {
        enable = true;
        displayManager.lightdm = {
          enable = true;
          greeters.gtk = {
            enable = true;
            theme = {
              package = pkgs.arc-theme;
              name = "Arc-Dark";
            };
            iconTheme = {
              package = pkgs.arc-icon-theme;
              name = "Arc";
            };
          };
        };
        windowManager.session = lib.singleton {
          name = "niri";
          start = "${pkgs-unstable.niri}/bin/niri-session";
        };
      };
      displayManager.defaultSession = "niri";
    })
  ];

  security.polkit.enable = true;
  
  # Update PAM services for display managers
  security.pam.services = if autoLogin then {
    greetd.enableGnomeKeyring = true;
  } else {
    lightdm.enableGnomeKeyring = true;
  };
} 