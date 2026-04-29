{
  config,
  pkgs,
  lib,
  inputs,
  useDms ? false,
  ...
}:

{
  qt = {
    enable = true;
    # In DMS mode, route Qt through qtct so DMS's matugen-rendered
    # qt5ct/qt6ct color schemes apply. Outside DMS, fall back to the
    # static adwaita platformtheme + style for native-looking GTK pairing.
    platformTheme.name = if useDms then "qtct" else "adwaita";
    style.name = lib.mkIf (!useDms) "adwaita-dark";
  };

  # Different package set per mode:
  #   - useDms=true  → qt5ct/qt6ct read DMS's color scheme files
  #   - useDms=false → adwaita-qt mimics GTK's Adwaita visually
  home.packages =
    if useDms
    then [ pkgs.libsForQt5.qt5ct pkgs.qt6Packages.qt6ct ]
    else [ pkgs.adwaita-qt pkgs.adwaita-qt6 ];
}
