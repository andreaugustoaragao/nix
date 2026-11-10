{
  lib,
  rustPlatform,
  pkg-config,
  makeWrapper,
  zig,
  wayland,
  libxkbcommon,
  vulkan-loader,
  libGL,
  libx11,
  libxcursor,
  libxi,
  libxrandr,
}:
let
  libraries = [
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
  pname = "rebuild-log-rune";
  version = "0.1.0";
  src = builtins.path {
    name = "rebuild-log-rune-source";
    path = ../home/desktop/rebuild-log-rune;
  };
  cargoLock = {
    lockFile = ../home/desktop/rebuild-log-rune/Cargo.lock;
    outputHashes."rune-0.0.1" = "sha256-e6f1kr0qvTT13YKZIGhiFee33RwydeVX60Yz23j/cQA=";
  };
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
  postInstall = ''
    install -Dm644 assets/Cascadia-LICENSE.txt "$out/share/doc/rebuild-log-rune/Cascadia-LICENSE.txt"
    wrapProgram "$out/bin/rebuild-log-rune" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath libraries}"
  '';
  meta = {
    description = "Native Rune viewer for live NixOS rebuild logs";
    license = [
      lib.licenses.mit
      lib.licenses.ofl
    ];
    platforms = lib.platforms.linux;
    mainProgram = "rebuild-log-rune";
  };
}
