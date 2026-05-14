{ pkgs, ... }:

{
  # Home Manager auto-enables xdg.portal and sets NIX_XDG_DESKTOP_PORTAL_DIR
  # in the user systemd environment, pointing at a buildEnv of just its own
  # `extraPortals`. That env var wins over the system-level one for every
  # user-scoped service — including xdg-desktop-portal.service.
  #
  # Without this module the HM portals dir only contains hyprland.portal
  # (auto-added by the HM hyprland module), so the gnome+gtk backends
  # that system/desktop.nix needs for ScreenCast / RemoteDesktop /
  # FileChooser are invisible to the running portal: niri-portals.conf
  # asks for `gnome` and the lookup fails, leaving the corresponding
  # D-Bus interfaces unadvertised. Result: screen sharing silently dies.
  #
  # Mirror the system extraPortals here so the merged HM portals dir has
  # every backend that niri-portals.conf can name.
  xdg.portal.extraPortals = with pkgs; [
    xdg-desktop-portal-gnome
    xdg-desktop-portal-gtk
  ];
}
