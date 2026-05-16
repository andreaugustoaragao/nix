{
  pkgs,
  lib,
  ...
}:
let
  baseSettings = ''
    [main]
    layer=overlay
    width=50
    lines=12
    horizontal-pad=16
    vertical-pad=12
    inner-pad=8
    line-height=22
    icon-theme=Papirus-Dark
    terminal=ghostty -e
    fields=name,generic,comment,categories,filename,keywords

    [border]
    width=2
    radius=8
  '';

  # Catppuccin Mocha — paired with the dark variant used everywhere else
  # (zed, ghostty, nvim, bat, lualine). 0xf2 alpha on the background
  # gives the same translucency the matugen-driven file used to have.
  mochaIni = ''
    ${baseSettings}
    [colors]
    background=1e1e2ef2
    text=cdd6f4ff
    match=89b4faff
    selection=313244ff
    selection-text=cdd6f4ff
    selection-match=89b4faff
    border=6c7086ff
  '';

  # Catppuccin Latte — light counterpart.
  latteIni = ''
    ${baseSettings}
    [colors]
    background=eff1f5f2
    text=4c4f69ff
    match=1e66f5ff
    selection=ccd0daff
    selection-text=4c4f69ff
    selection-match=1e66f5ff
    border=9ca0b0ff
  '';
in
{
  # Papirus provides icons for nearly every Linux desktop app — without
  # it fuzzel silently shows entries with no icon.
  home.packages = [
    pkgs.papirus-icon-theme
    pkgs.fuzzel
  ];

  # Both palettes ship as immutable store files. The actual fuzzel.ini
  # is a writable symlink at ~/.config/fuzzel/fuzzel.ini that points at
  # one of these — flipped by darkman (see home/services/darkman.nix)
  # when the system color-scheme toggles, and seeded on rebuild by the
  # activation script below.
  xdg.configFile = {
    "fuzzel/fuzzel.mocha.ini".text = mochaIni;
    "fuzzel/fuzzel.latte.ini".text = latteIni;
  };

  # Point fuzzel.ini at the variant matching the current portal
  # color-scheme on rebuild. Falls back to mocha if gsettings isn't
  # answering (e.g. headless / first boot). The link target is relative
  # so the symlink stays valid across store-path churn.
  home.activation.fuzzelTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target=fuzzel.mocha.ini
    if mode=$(${pkgs.glib}/bin/gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null); then
      case "$mode" in
        *prefer-light*) target=fuzzel.latte.ini ;;
      esac
    fi
    ${pkgs.coreutils}/bin/ln -sfn "$target" "$HOME/.config/fuzzel/fuzzel.ini"
  '';
}
