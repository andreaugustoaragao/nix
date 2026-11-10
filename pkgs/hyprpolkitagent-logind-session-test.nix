{
  stdenv,
  pkg-config,
  qt6,
  dbus,
  src,
  patches,
}:
stdenv.mkDerivation {
  pname = "hyprpolkitagent-logind-session-test";
  version = "1";
  inherit src patches;

  nativeBuildInputs = [
    pkg-config
    dbus
  ];
  buildInputs = [ qt6.qtbase ];
  dontWrapQtApps = true;

  buildPhase = ''
    runHook preBuild
    $CXX -std=c++17 -fPIC -I. ${./hyprpolkitagent-logind-session.test.cpp} \
      -o logind-session-test $(pkg-config --cflags --libs Qt6Core Qt6DBus)
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    dbus-run-session --config-file=${dbus}/share/dbus-1/session.conf -- sh -c \
      'export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"; exec ./logind-session-test'
    runHook postCheck
  '';

  installPhase = ''
    touch "$out"
  '';
}
