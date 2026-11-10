{
  lib,
  rustPlatform,
  pkg-config,
  makeWrapper,
  glib,
  gvfs,
  wayland,
  libxkbcommon,
  vulkan-loader,
  libGL,
  libx11,
  libxcursor,
  libxi,
  libxrandr,
  xdg-utils,
}:
let
  libraries = [
    glib
    wayland
    libxkbcommon
    vulkan-loader
    libGL
    libx11
    libxcursor
    libxi
    libxrandr
  ];
in
rustPlatform.buildRustPackage {
  pname = "yazi-rune";
  version = "0.1.0";
  src = builtins.path {
    name = "yazi-rune-source.tar.gz";
    path = ./sources/yazi-rune-source.tar.gz;
  };
  sourceRoot = "source/rune-app";
  cargoLock = {
    lockFile = ./sources/yazi-rune-Cargo.lock;
    outputHashes."rune-0.0.1" = "sha256-e6f1kr0qvTT13YKZIGhiFee33RwydeVX60Yz23j/cQA=";
  };
  buildType = "debug";
  nativeBuildInputs = [
    pkg-config
    makeWrapper
  ];
  buildInputs = libraries;
  doCheck = false;
  postInstall = ''
    cp -r share "$out/share"
    substituteInPlace "$out/share/applications/io.github.yazi_rune.desktop" \
      --replace-fail '@out@' "$out"
    substituteInPlace "$out/share/dbus-1/services/org.freedesktop.FileManager1.service" \
      --replace-fail '@out@' "$out"
    wrapProgram "$out/bin/yazi-rune" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath libraries}" \
      --prefix GIO_EXTRA_MODULES : "${gvfs}/lib/gio/modules" \
      --prefix PATH : "${
        lib.makeBinPath [
          glib
          xdg-utils
        ]
      }"
  '';
  meta = {
    description = "Native Rune file manager with Yazi keyboard navigation";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "yazi-rune";
  };
}
