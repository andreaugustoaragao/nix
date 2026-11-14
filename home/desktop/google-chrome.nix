{ pkgs, unstable-pkgs, ... }:
{
  programs.chromium = {
    enable = true;
    package = (pkgs.callPackage ../../pkgs/browser-system-theme.nix { }) {
      browser = import ../../pkgs/chromium-ahead.nix {
        inherit (pkgs) lib;
        inherit (unstable-pkgs) chromium;
      };
      name = "chromium";
    };
    commandLineArgs = [
      "--enable-features=UseOzonePlatform"
      "--ozone-platform=wayland"
      "--password-store=gnome-libsecret"
    ];
    extensions = [
      # Bitwarden Password Manager
      { id = "nngceckbapebfimnlniiiahkandclblb"; }
      # Vimium
      { id = "dbepggeogbaibhgnhhndojpepiihcmeb"; }
      # Markdown Viewer
      { id = "ckkdlimhmcjmikdlpkmbgfkaikojcbjk"; }
    ];
  };
}
