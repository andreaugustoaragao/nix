{ config, pkgs, lib, inputs, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  # Brave Browser configuration using unstable version
  programs.brave = {
    enable = true;
    package = pkgs-unstable.brave;
    commandLineArgs = [
      # Wayland flags for proper Wayland support
      "--enable-features=UseOzonePlatform"
      "--ozone-platform=wayland"
      "--disable-features=BraveRewards"  # Disable Brave Rewards
      "--disable-brave-ads"              # Disable Brave Ads
      "--disable-background-mode"        # Prevent running in background
      "--password-store=gnome-libsecret"
    ];
    extensions = [
      # Bitwarden Password Manager
      {
        id = "nngceckbapebfimnlniiiahkandclblb";
      }
      # Vimium - vim-like navigation
      {
        id = "dbepggeogbaibhgnhhndojpepiihcmeb";
      }
      # Kanagawa theme
      {
        id = "djnghjlejbfgnbnmjfgbdaeafbiklpha";
      }
    ];
  };

} 