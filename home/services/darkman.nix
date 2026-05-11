{
  pkgs,
  lib,
  useDms ? false,
  ...
}:

# darkman writes the gsettings color-scheme key so xdg-desktop-portal
# Settings reflects the active mode. DMS *would* do this write itself
# on mode toggle, but Theme.qml:1001-1003 skips it whenever matugen is
# available (matugen is expected to cover GTK/Qt theming via its own
# templates). Any portal-reading app *not* covered by the user's
# matugen template set (see home/desktop/matugen.nix) won't follow DMS
# mode without this — darkman fills that gap.
#
# Triggered alongside `dms ipc call theme toggle` from the niri keybind
# (see home/desktop/niri.nix). Wallpaper swap is handled by DMS itself
# via SessionData.syncWallpaperForCurrentMode(); darkman does not
# affect wallpapers (DMS has no listener for portal SettingChanged).
lib.mkIf useDms {
  services.darkman = {
    enable = true;
    settings = {
      usegeoclue = false;
    };
    darkModeScripts.gnome-color-scheme = ''
      ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    '';
    lightModeScripts.gnome-color-scheme = ''
      ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-light'
    '';
  };
}
