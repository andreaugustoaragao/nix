{
  lib,
  callPackage,
  fetchFromGitHub,
  makeRustPlatform,
  runCommand,
  zig_0_16,
  clang,
  pkg-config,
  makeWrapper,
  makeDesktopItem,
  copyDesktopItems,
  fontconfig,
  freetype,
  libxcb,
  libxkbcommon,
  libGL,
  vulkan-loader,
  wayland,
  xdg-utils,
  herdr-core,
}:
let
  version = "0.1.12";
  rustToolchain = callPackage ./rust-toolchain.nix { };
  rustPlatform = makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
  src = fetchFromGitHub {
    owner = "herdrdev";
    repo = "herdr-app";
    rev = "4aa3460749947e7771aa39a8a2cec58d46649926";
    fetchSubmodules = true;
    hash = "sha256-sFuggPKc3hsFD6YSqQB3gNoDFZsj49zaiaNiQBS5cAA=";
  };
  zigDeps =
    runCommand "herdr-app-${version}-zig-deps"
      {
        inherit src;
        nativeBuildInputs = [ zig_0_16 ];
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = "sha256-G9xbZ/pyQTDIfzG0h++i70a45zpwyYpZMBZfAnoOQw0=";
      }
      ''
        unpackPhase
        cd "$sourceRoot/vendor/ghostty"
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
        zig build -Demit-lib-vt -Doptimize=ReleaseFast --fetch=all
        mv "$ZIG_GLOBAL_CACHE_DIR/p" "$out"
      '';
  runtimeLibs = [
    libGL
    vulkan-loader
    wayland
  ];
in
rustPlatform.buildRustPackage {
  pname = "herdr-app";
  inherit version src;
  patches = [ ./patches/herdr-app-virgl.patch ];
  cargoHash = "sha256-yij8NJni+VtIvtMXxpsj1E/izo90RiY6VeV8Czs8nQk=";
  env.ZIG = lib.getExe zig_0_16;

  nativeBuildInputs = [
    clang
    pkg-config
    rustPlatform.bindgenHook
    makeWrapper
    copyDesktopItems
  ];
  buildInputs = [
    fontconfig
    freetype
    libxcb
    libxkbcommon
  ]
  ++ runtimeLibs;
  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    ln -s ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';
  # Native graphics and the full suite are verified on the target GPU;
  # the upstream suite also assumes conventional /bin and /usr/bin paths.
  doCheck = false;
  desktopItems = [
    (makeDesktopItem {
      name = "herdr-app";
      desktopName = "Herdr";
      comment = "Terminals and coding agents that keep running";
      exec = "herdr-app";
      icon = "herdr-app";
      categories = [ "Development" ];
      startupWMClass = "herdr-app";
    })
  ];
  postInstall = ''
    install -Dm644 assets/icons/herdr-ui-icon-clean.svg "$out/share/icons/hicolor/scalable/apps/herdr-app.svg"
    install -Dm644 LICENSE "$out/share/licenses/herdr-app/LICENSE"
    install -Dm644 THIRD-PARTY-NOTICES "$out/share/licenses/herdr-app/THIRD-PARTY-NOTICES"
    wrapProgram "$out/bin/herdr-app" \
      --prefix PATH : ${lib.makeBinPath [ herdr-core ]} \
      --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibs} \
      --set WGPU_BACKEND gl \
      --set VK_DRIVER_FILES /dev/null \
      --unset LIBGL_ALWAYS_SOFTWARE
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/herdr-app" --version
    runHook postInstallCheck
  '';
  passthru = {
    inherit zigDeps;
    compatibilityRenderer = true;
  };
  meta = {
    description = "Herdr desktop with OpenGL 4.0 / ES 3.0 compatibility rendering";
    homepage = "https://github.com/herdrdev/herdr-app";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-linux" ];
    mainProgram = "herdr-app";
  };
}
