{ unstable-pkgs, ... }:
{
  programs.chromium = {
    enable = true;
    package = unstable-pkgs.chromium;
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
      # Claude in Chrome
      { id = "fcoeoabgfenejglbffodgkkbkcdhcgfn"; }
      # Markdown Viewer
      { id = "ckkdlimhmcjmikdlpkmbgfkaikojcbjk"; }
    ];
  };
}
