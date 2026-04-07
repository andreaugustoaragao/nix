{ config, pkgs, lib, inputs, ... }:

{
  gtk = {
    enable = true;
    theme = {
      name = "Adwaita";
    };
    iconTheme = {
      name = "Yaru-blue";
      package = pkgs.yaru-theme;
    };
    cursorTheme = {
      name = "Bibata-Modern-Classic";
      package = pkgs.bibata-cursors;
      size = 24;
    };
    gtk3.extraConfig = {
      gtk-application-prefer-dark-theme = 1;
    };
    gtk4.extraConfig = {
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
      icon-theme = "Yaru-blue";
      cursor-theme = "Bibata-Modern-Classic";
      color-scheme = "prefer-dark";
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