{
  config,
  pkgs,
  lib,
  hostName,
  appearance,
  useDms ? false,
  useNoctalia ? false,
  ...
}:

let
  integratedShell = useDms || useNoctalia;
  iconTheme = if integratedShell then "Papirus-Dark" else "Yaru-blue";
  iconPkg = if integratedShell then pkgs.papirus-icon-theme else pkgs.yaru-theme;
  # adw-gtk3 6.5 ships a gtk-4.0/libadwaita.css using GTK 4.20 @media rules that
  # GTK 4.18 portals (xdg-desktop-portal-gnome) reject with parser warnings.
  # GTK4 apps already receive native Adwaita + ~/.config/gtk-4.0/gruvbox.css.
  adwGtk3Only = pkgs.runCommand "adw-gtk3-gtk3-only" { } ''
    for variant in adw-gtk3 adw-gtk3-dark; do
      mkdir -p "$out/share/themes/$variant"
      ln -s "${pkgs.adw-gtk3}/share/themes/$variant/gtk-3.0" "$out/share/themes/$variant/gtk-3.0"
      ln -s "${pkgs.adw-gtk3}/share/themes/$variant/index.theme" "$out/share/themes/$variant/index.theme"
    done
  '';
in
{
  gtk = {
    enable = true;
    # Match the personal VM explicitly, including apps that read GTK's
    # settings.ini rather than the desktop portal's current font setting.
    font = lib.mkIf (hostName == "prl-dev-vm") {
      name = "Noto Sans";
      size = 10;
      package = pkgs.noto-fonts;
    };
    # Adwaita stays the structural base in both modes; DMS's
    # matugen-generated `dank-colors.css` is symlinked at gtk.css and
    # overlays Adwaita with the wallpaper-derived palette when useDms.
    theme =
      if appearance.isGruvbox then
        null
      else
        {
          name = "Adwaita";
        };
    # 26.05 changed the gtk4 theme default from `config.gtk.theme` to null;
    # pin it to Adwaita to keep the pre-upgrade gtk4 appearance.
    gtk4.theme =
      if appearance.isGruvbox then
        null
      else
        {
          name = "Adwaita";
        };
    gtk2.extraConfig = lib.optionalString appearance.isGruvbox ''
      include "${config.xdg.configHome}/gtk-2.0/gruvbox.rc"
    '';
    gtk3.extraCss = lib.optionalString appearance.isGruvbox ''
      @import url("gruvbox.css");
    '';
    gtk4.extraCss = lib.optionalString appearance.isGruvbox ''
      @import url("gruvbox.css");
    '';
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
    gtk3.extraConfig = lib.mkIf (!integratedShell) {
      gtk-application-prefer-dark-theme = 1;
    };
    gtk4.extraConfig = lib.mkIf (!integratedShell) {
      gtk-application-prefer-dark-theme = 1;
    };
  };

  # Adwaita ships a complete symbolic icon set. Papirus/Yaru inherit from
  # it, but a few symbolic names DMS/Qt request (input-keyboard-symbolic,
  # application-x-executable, …) aren't in those themes; installing Adwaita
  # into the profile makes them resolvable via the icon-lookup fallback.
  home.packages = [
    pkgs.adwaita-icon-theme
  ]
  ++ lib.optionals appearance.isGruvbox [
    adwGtk3Only
    pkgs.gruvbox-gtk-theme
  ];
  xdg.configFile = lib.mkIf appearance.isGruvbox {
    "gtk-3.0/gtk.css".force = true;
    "gtk-4.0/gtk.css".force = true;
  };

  # User avatar. DMS (and other freedesktop consumers) look for ~/.face;
  # mirror the AccountsService login avatar here so the shell profile pic
  # and lock screen render instead of falling back to a placeholder.
  home.file.".face".source = ../../assets/avatar.png;

  # Ensure GTK3 uses xdg-desktop-portal for file dialogs, etc.
  home.sessionVariables = {
    GTK_USE_PORTAL = "1";
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      gtk-theme = lib.mkIf (!appearance.isGruvbox) "Adwaita";
      icon-theme = lib.mkIf (!appearance.isGruvbox) iconTheme;
      cursor-theme = "Bibata-Modern-Classic";
      # In DMS mode the portal owns the color-scheme; don't pin it here.
      color-scheme = lib.mkIf (!integratedShell) "prefer-dark";
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
