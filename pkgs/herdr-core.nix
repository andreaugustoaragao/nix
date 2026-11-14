{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
}:

let
  version = "0.1.21";
  sources = {
    aarch64-linux = {
      target = "linux-aarch64";
      hash = "sha256-6ESiv6tIoiYJdnnQdryDBC/lf8zvU4fvgC5bJOeLUpo=";
    };
    x86_64-linux = {
      target = "linux-x86_64";
      hash = "sha256-eEJHVcEKQN3jigvbVcIKwZcG6a4F7Wj8Ks8fz/DZQcE=";
    };
    aarch64-darwin = {
      target = "macos-aarch64";
      hash = "sha256-GrON2ScPY6j3lNbWDocC6w0chacr2oXXNeXupD8F/+0=";
    };
    x86_64-darwin = {
      target = "macos-x86_64";
      hash = "sha256-43fh00LN3OA0baWy88KBuXAeRzHAACTHxQKCZed6IX8=";
    };
  };
  source = sources.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation {
  pname = "herdr-core";
  inherit version;

  src = fetchurl {
    url = "https://releases.herdr.dev/core/${version}/herdr-core-${source.target}.tar.gz";
    inherit (source) hash;
  };

  nativeBuildInputs = [ makeWrapper ];

  unpackPhase = ''
    runHook preUnpack
    tar -xzf "$src"
    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 herdr-core "$out/bin/herdr-core"
    wrapProgram "$out/bin/herdr-core" --unset NO_COLOR
    ln -s herdr-core "$out/bin/hc"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/hc" --version
    runHook postInstallCheck
  '';

  meta = {
    description = "Persistent terminal runtime for Herdr desktop and coding agents";
    homepage = "https://github.com/herdrdev/herdr-core";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "hc";
  };
}
