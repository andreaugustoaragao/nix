{
  lib,
  callPackage,
  rustPlatform,
  pkg-config,
  makeWrapper,
  zig,
  glib,
  cairo,
  pango,
  gdk-pixbuf,
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
  veredaSource ? lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../build.rs
      ../LICENSE
      ../THIRD_PARTY_NOTICES.md
      (lib.fileset.fileFilter (file: file.hasExt "rs" || file.hasExt "c") ../src)
      ../share
    ];
  },
  lockFile ? ../Cargo.lock,
}:
let
  runeSource = callPackage ./rune-source.nix { };
  libraries = [
    glib
    cairo
    pango
    gdk-pixbuf
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
  pname = "vereda";
  version = "0.1.0";
  src = veredaSource;
  cargoLock.lockFile = lockFile;
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
    install -Dm644 -t "$out/share/licenses/vereda" LICENSE THIRD_PARTY_NOTICES.md
    substituteInPlace "$out/share/applications/io.github.andrearagao.vereda.desktop" \
      --replace-fail '@out@' "$out"
    substituteInPlace "$out/share/dbus-1/services/org.freedesktop.FileManager1.service" \
      --replace-fail '@out@' "$out"
    substituteInPlace "$out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.vereda.service" \
      --replace-fail '@out@' "$out"
    substituteInPlace "$out/share/systemd/user/xdg-desktop-portal-vereda.service" \
      --replace-fail '@out@' "$out"
    wrapProgram "$out/bin/vereda" \
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
    description = "Native Linux file manager, navigator, and previewer";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "vereda";
  };
}
