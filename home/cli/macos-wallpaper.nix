{
  lib,
  wallpapers,
  ...
}:

# macOS doesn't expose a declarative `system.defaults` option for the
# desktop wallpaper, so we drive it via AppleScript on every
# home-manager activation. `System Events → every desktop` iterates
# all connected displays, which matches how Linux per-monitor
# wallpapers behave (see home/desktop/quickshell.nix).
#
# To change the image, swap `wallpaperImage` for any other file the
# wallpapers derivation in home/desktop/wallpapers.nix exposes.

let
  wallpaperImage = "${wallpapers}/share/wallpapers/fuji-pagoda-sunset.jpg";
in
{
  home.activation.setMacOSWallpaper = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    /usr/bin/osascript -e 'tell application "System Events" to tell every desktop to set picture to "${wallpaperImage}"' || true
  '';
}
