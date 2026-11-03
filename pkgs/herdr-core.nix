{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
}:

let
  version = "0.1.17";
  sources = {
    aarch64-linux = {
      target = "linux-aarch64";
      hash = "sha256-OjekVOxjSUz0MG2yZIH+nblmc9iIcjcB0k+KmSroq4w=";
    };
    x86_64-linux = {
      target = "linux-x86_64";
      hash = "sha256-guxEBD9olL/bcWuXm4fNpD/X+kawEE57e9k+ZNGpuHc=";
    };
    aarch64-darwin = {
      target = "macos-aarch64";
      hash = "sha256-ztvU1Nm6E4VYgZjdTTxn0mVEePM63VtkRdTQ652l/PM=";
    };
    x86_64-darwin = {
      target = "macos-x86_64";
      hash = "sha256-4twyEe2x8cd9DnPddsFCZjbXEFDzSlMDkWpW02PXBis=";
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
