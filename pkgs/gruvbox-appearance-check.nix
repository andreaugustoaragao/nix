{
  lib,
  runCommand,
  python3,
  stdenv,
  gtk3,
  gtk4,
  libsForQt5,
  qt6Packages,
  glib,
  gsettings-desktop-schemas,
}:
let
  appearance = import ../home/appearance/palette.nix {
    inherit lib;
    colorScheme = "gruvbox";
  };
  toolkit = import ../home/appearance/toolkit.nix { inherit lib appearance; };
  data = builtins.toJSON {
    inherit toolkit;
    inherit (appearance) dark light;
  };
  python = python3.withPackages (
    ps:
    [
      ps.tomlkit
      ps.json5
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      ps.pyqt5
      ps.pyqt6
    ]
  );
  source = builtins.path {
    name = "appearance-tests";
    path = ../home/appearance;
  };
in
runCommand "check-gruvbox-appearance" { } ''
  export PYTHONDONTWRITEBYTECODE=1
  export TEST_GSETTINGS=${glib}/bin/gsettings
  export TEST_GSETTINGS_SCHEMA_DIR=${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}/glib-2.0/schemas
  ${lib.getExe python} ${source}/configure.test.py
  ${lib.getExe python} ${source}/toolkit.test.py ${builtins.toFile "gruvbox-toolkit.json" data}
  ${lib.optionalString stdenv.hostPlatform.isLinux ''
    ${lib.getExe python} ${source}/gtk.test.py ${builtins.toFile "gruvbox-toolkit.json" data} gtk3 ${gtk3}/lib/libgtk-3.so.0
    ${lib.getExe python} ${source}/gtk.test.py ${builtins.toFile "gruvbox-toolkit.json" data} gtk4 ${gtk4}/lib/libgtk-4.so.1
    ${lib.getExe python} ${source}/qt.test.py ${builtins.toFile "gruvbox-toolkit.json" data} 5 ${libsForQt5.qt5ct}/${libsForQt5.qtbase.qtPluginPrefix}:${libsForQt5.qtbase}/${libsForQt5.qtbase.qtPluginPrefix}
    ${lib.getExe python} ${source}/qt.test.py ${builtins.toFile "gruvbox-toolkit.json" data} 6 ${qt6Packages.qt6ct}/lib/qt-6/plugins:${qt6Packages.qtbase}/${qt6Packages.qtbase.qtPluginPrefix}
  ''}
  touch "$out"
''
