{
  lib,
  callPackage,
  rustPlatform,
  pkg-config,
  makeWrapper,
  zig,
  glib,
  fontconfig,
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
  poppler-utils,
  gdb,
}:
let
  runeSource = callPackage ./sources/rune-source.nix { };
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
  };
  postPatch = ''
    ln -s ${runeSource} .rune-source
  '';
  buildType = "debug";
  dontUseZigConfigure = true;
  dontUseZigBuild = true;
  dontUseZigCheck = true;
  dontUseZigInstall = true;
  nativeBuildInputs = [
    pkg-config
    makeWrapper
    zig
    rustPlatform.bindgenHook
  ];
  buildInputs = libraries;
  doCheck = false;
  postInstall = ''
    cp -r share "$out/share"
    substituteInPlace "$out/share/applications/io.github.yazi_rune.desktop" \
      --replace-fail '@out@' "$out"
    substituteInPlace "$out/share/dbus-1/services/org.freedesktop.FileManager1.service" \
      --replace-fail '@out@' "$out"
    substituteInPlace "$out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.rune.service" \
      --replace-fail '@out@' "$out"
    substituteInPlace "$out/share/systemd/user/xdg-desktop-portal-rune.service" \
      --replace-fail '@out@' "$out"
    wrapProgram "$out/bin/yazi-rune" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath libraries}" \
      --prefix GIO_EXTRA_MODULES : "${gvfs}/lib/gio/modules" \
      --prefix PATH : "${
        lib.makeBinPath [
          glib
          fontconfig
          xdg-utils
          poppler-utils
          gdb
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
