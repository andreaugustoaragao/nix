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

    # Flip fuzzel's active config between the two Catppuccin variants
    # (see home/desktop/fuzzel.nix). fuzzel re-reads its config on each
    # launch, so no signal/reload step is needed.
    darkModeScripts.fuzzel = ''
      ${pkgs.coreutils}/bin/ln -sfn fuzzel.mocha.ini "$HOME/.config/fuzzel/fuzzel.ini"
    '';
    lightModeScripts.fuzzel = ''
      ${pkgs.coreutils}/bin/ln -sfn fuzzel.latte.ini "$HOME/.config/fuzzel/fuzzel.ini"
    '';

    # Flip starship's active config the same way (see
    # home/cli/starship.nix). starship reads STARSHIP_CONFIG on every
    # prompt eval, so existing shells pick up the swap on the next
    # prompt with no reload.
    darkModeScripts.starship = ''
      ${pkgs.coreutils}/bin/ln -sfn starship.mocha.toml "$HOME/.config/starship/starship.toml"
    '';
    lightModeScripts.starship = ''
      ${pkgs.coreutils}/bin/ln -sfn starship.latte.toml "$HOME/.config/starship/starship.toml"
    '';

    # Flip foot between [colors] (Mocha) and [colors2] (Latte) — see
    # home/desktop/foot.nix. SIGUSR1/2 to the server updates all
    # footclient windows; foot does not read the portal on its own.
    darkModeScripts.foot = ''
      ${pkgs.procps}/bin/pkill -SIGUSR1 -x foot 2>/dev/null || true
    '';
    lightModeScripts.foot = ''
      ${pkgs.procps}/bin/pkill -SIGUSR2 -x foot 2>/dev/null || true
    '';
  };
}
