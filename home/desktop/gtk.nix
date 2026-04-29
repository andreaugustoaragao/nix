{
  config,
  pkgs,
  lib,
  inputs,
  useDms ? false,
  ...
}:

let
  iconTheme = if useDms then "Papirus-Dark" else "Yaru-blue";
  iconPkg   = if useDms then pkgs.papirus-icon-theme else pkgs.yaru-theme;
in
{
  gtk = {
    enable = true;
    # Adwaita stays the structural base in both modes; DMS's
    # matugen-generated `dank-colors.css` is symlinked at gtk.css and
    # overlays Adwaita with the wallpaper-derived palette when useDms.
    theme = {
      name = "Adwaita";
    };
    iconTheme = {
      name = iconTheme;
      package = iconPkg;
    };
    cursorTheme = {
      name = "Bibata-Modern-Classic";
      package = pkgs.bibata-cursors;
      size = 24;
    };
    # In DMS mode, the freedesktop color-scheme portal toggles dark/light
    # globally (syncModeWithPortal=true). Forcing prefer-dark-theme here
    # would override the portal and break light-mode switching.
    gtk3.extraConfig = lib.mkIf (!useDms) {
      gtk-application-prefer-dark-theme = 1;
    };
    gtk4.extraConfig = lib.mkIf (!useDms) {
      gtk-application-prefer-dark-theme = 1;
    };
  };

  # Ensure GTK3 uses xdg-desktop-portal for file dialogs, etc.
  home.sessionVariables = {
    GTK_USE_PORTAL = "1";
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      gtk-theme = "Adwaita";
      icon-theme = iconTheme;
      cursor-theme = "Bibata-Modern-Classic";
      # In DMS mode the portal owns the color-scheme; don't pin it here.
      color-scheme = lib.mkIf (!useDms) "prefer-dark";
    };

    "org/gtk/settings/file-chooser" = {
      show-type-column = true;
      sidebar-width = 152;
      date-format = "with-time";
      location-mode = "path-bar";
      show-hidden = true;
      show-size-column = true;
      sort-column = "modified";
      sort-directories-first = true;
      sort-order = "ascending";
      type-format = "category";
    };
  };
}
