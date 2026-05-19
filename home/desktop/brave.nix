{ pkgs, inputs, ... }:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
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
      "--disable-features=BraveRewards" # Disable Brave Rewards
      "--disable-brave-ads" # Disable Brave Ads
      "--disable-background-mode" # Prevent running in background
      "--password-store=gnome-libsecret"
    ];
    # Soft extension installs: a JSON manifest is dropped into Brave's
    # External Extensions/ dir, so the extension shows up on first
    # profile creation but the user can disable or remove it later.
    # The force-installed daily drivers (Bitwarden, Vimium, Markdown
    # Viewer) live in system/browsers.nix instead — those use the
    # ExtensionSettings policy, which auto-installs them, blocks
    # uninstall, and force-pins their toolbar icon across both
    # profiles.
    extensions = [
      # Claude in Chrome
      {
        id = "fcoeoabgfenejglbffodgkkbkcdhcgfn";
      }
    ];
  };

}
