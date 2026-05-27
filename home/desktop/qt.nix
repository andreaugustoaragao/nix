{
  config,
  pkgs,
  lib,
  useDms ? false,
  ...
}:

let
  qt6ctConf = pkgs.writeText "qt6ct.conf" ''
    [Appearance]
    color_scheme_path=${config.home.homeDirectory}/.config/qt6ct/colors/matugen.conf
    custom_palette=true
    standard_dialogs=default
    style=Fusion

    [Fonts]
    fixed="DejaVu Sans,12,-1,5,50,0,0,0,0,0"
    general="DejaVu Sans,12,-1,5,50,0,0,0,0,0"

    [Interface]
    activate_item_on_single_click=1
    buttonbox_layout=0
    cursor_flash_time=1000
    dialog_buttons_have_icons=1
    double_click_interval=400
    gui_effects=@Invalid()
    keyboard_scheme=2
    menus_have_icons=true
    show_shortcuts_in_context_menus=true
    stylesheets=@Invalid()
    toolbutton_style=4
    underline_shortcut=1
    wheel_scroll_lines=3

    [Troubleshooting]
    force_raster_widgets=1
    ignored_applications=@Invalid()
  '';
in
{
  qt = {
    enable = true;
    # In DMS mode, route Qt through qtct so DMS's matugen-rendered
    # qt5ct/qt6ct color schemes apply. Outside DMS, fall back to the
    # static adwaita platformtheme + style for native-looking GTK pairing.
    platformTheme.name = if useDms then "qtct" else "adwaita";
    style.name = lib.mkIf (!useDms) "adwaita-dark";
  };

  # Home Manager's `qtct` shorthand sets QT_QPA_PLATFORMTHEME=qt5ct,
  # which themes Qt5 apps only — Qt6 apps look for a `qt6ct` plugin id
  # and silently load nothing. Force qt6ct since modern Qt apps are Qt6.
  home.sessionVariables = lib.mkIf useDms {
    QT_QPA_PLATFORMTHEME = lib.mkForce "qt6ct";
  };

  # Different package set per mode:
  #   - useDms=true  → qt5ct/qt6ct read DMS's color scheme files
  #   - useDms=false → adwaita-qt mimics GTK's Adwaita visually
  home.packages =
    if useDms then
      [
        pkgs.libsForQt5.qt5ct
        pkgs.qt6Packages.qt6ct
      ]
    else
      [
        pkgs.adwaita-qt
        pkgs.adwaita-qt6
      ];

  # qt6ct never wrote a real config on its own, so it ignored DMS's
  # color scheme. Pin qt6ct.conf to the matugen palette + Fusion style
  # (Fusion is the only Qt6 style that honors custom_palette fully).
  # Installed as a writable file (not a /nix/store symlink) because DMS
  # touches qt6ct.conf on every theme switch to nudge Qt apps to reload.
  home.activation.qt6ctConf = lib.mkIf useDms (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p "$HOME/.config/qt6ct"
      run rm -f "$HOME/.config/qt6ct/qt6ct.conf"
      run install -m 644 "${qt6ctConf}" "$HOME/.config/qt6ct/qt6ct.conf"
    ''
  );
}
