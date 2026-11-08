{
  lib,
  stdenv,
  fetchurl,
  callPackage,
  autoPatchelfHook,
  makeWrapper,
  makeDesktopItem,
  copyDesktopItems,
  fontconfig,
  libxcb,
  libxkbcommon,
  libGL,
  vulkan-loader,
  wayland,
  xdg-utils,
  herdr-core ? callPackage ./herdr-core.nix { },
  compatibilityRenderer ? stdenv.hostPlatform.isAarch64,
}:

let
  version = "0.1.12";
  sources = {
    aarch64-linux = {
      target = "linux-aarch64";
      hash = "sha256-dJ8x0w4/TX4k4nSPdNnLSpvdpMloAnq6/7b7I5/+tpQ=";
    };
    x86_64-linux = {
      target = "linux-x86_64";
      hash = "sha256-omXmySXEh0WEBnQf+gnS+g09S9QBo07YwBwzYQjlfB8=";
    };
  };
  source = sources.${stdenv.hostPlatform.system};
  runtimeLibs = [
    libGL
    vulkan-loader
    wayland
  ];
in
if compatibilityRenderer then
  callPackage ./herdr-app-source.nix { inherit herdr-core; }
else
  stdenv.mkDerivation {
    pname = "herdr-app";
    inherit version;

    src = fetchurl {
      url = "https://releases.herdr.dev/app/${version}/herdr-app-${source.target}.tar.gz";
      inherit (source) hash;
    };

    nativeBuildInputs = [
      autoPatchelfHook
      makeWrapper
      copyDesktopItems
    ];
    buildInputs = [
      fontconfig
      libxcb
      libxkbcommon
      stdenv.cc.cc.lib
    ]
    ++ runtimeLibs;
    runtimeDependencies = runtimeLibs;

    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;

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

    installPhase = ''
      runHook preInstall
      install -Dm755 herdr-app "$out/bin/herdr-app"
      # An icon beside the executable enables Herdr's unmanaged self-updater.
      install -Dm644 herdr-app.svg "$out/share/icons/hicolor/scalable/apps/herdr-app.svg"
      install -Dm644 LICENSE "$out/share/licenses/herdr-app/LICENSE"
      install -Dm644 THIRD-PARTY-NOTICES "$out/share/licenses/herdr-app/THIRD-PARTY-NOTICES"
      wrapProgram "$out/bin/herdr-app" \
        --prefix PATH : ${lib.makeBinPath [ herdr-core ]} \
        --suffix PATH : ${lib.makeBinPath [ xdg-utils ]} \
        --set-default WGPU_BACKEND gl
      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      "$out/bin/herdr-app" --version
      runHook postInstallCheck
    '';

    meta = {
      description = "Native desktop workspace for terminals and coding agents";
      homepage = "https://github.com/herdrdev/herdr-app";
      license = lib.licenses.asl20;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      platforms = builtins.attrNames sources;
      mainProgram = "herdr-app";
    };
  }
