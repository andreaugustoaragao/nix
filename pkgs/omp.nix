{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  buildFHSEnv ? null,
}:
let
  version = "19.0.1";
  sources = {
    aarch64-linux = {
      target = "linux-arm64";
      hash = "sha256-I37eD0mU1h9SOALEz1YtTki650wYit15LQbQUbkHzs8=";
    };
    x86_64-linux = {
      target = "linux-x64";
      hash = "sha256-bO7wRDCFG7EFDG/aOvRnQS60ShHfCm/4Eh/mAQE8VBU=";
    };
    aarch64-darwin = {
      target = "darwin-arm64";
      hash = "sha256-L+Qgu9APgYmYFuUcvuuVk6+lnZNo1iydPnhTXVQOMvY=";
    };
    x86_64-darwin = {
      target = "darwin-x64";
      hash = "sha256-jWJQLu3ox6QzEXmENNCjGhwCSjq8Vr7cTaIAzM+U/qE=";
    };
  };
  source = sources.${stdenv.hostPlatform.system};
  meta = {
    description = "Oh My Pi terminal coding agent";
    homepage = "https://omp.sh";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "omp";
  };
  binary = stdenvNoCC.mkDerivation {
    pname = "omp-unwrapped";
    inherit version meta;
    src = fetchurl {
      url = "https://github.com/can1357/oh-my-pi/releases/download/v${version}/omp-${source.target}";
      inherit (source) hash;
    };
    dontUnpack = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      install -Dm755 "$src" "$out/bin/omp"
      runHook postInstall
    '';
  };
in
if stdenv.hostPlatform.isLinux then
  buildFHSEnv {
    pname = "omp";
    inherit version meta;
    targetPkgs = pkgs: [
      binary
      pkgs.stdenv.cc.cc.lib
      pkgs.alsa-lib
      pkgs.libpulseaudio
      pkgs.zlib
    ];
    runScript = "${binary}/bin/omp";
    passthru = { inherit binary; };
  }
else
  binary
