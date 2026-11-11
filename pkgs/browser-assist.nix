{
  lib,
  rustPlatform,
  pkg-config,
  makeWrapper,
  zig,
  browser-task,
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
  pname = "browser-assist";
  version = "0.1.0";
  src = builtins.path {
    name = "browser-assist-source";
    path = ../home/desktop/browser-assist;
    filter = path: type: !(type == "directory" && builtins.baseNameOf path == "target");
  };
  cargoLock = {
    lockFile = ../home/desktop/browser-assist/Cargo.lock;
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
    wrapProgram "$out/bin/browser-assist" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath libraries}" \
      --set BROWSER_TASK_BIN "${lib.getExe browser-task}"
  '';
  meta = {
    description = "Native browser assistance with private inputs and screenshots";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "browser-assist";
  };
}
