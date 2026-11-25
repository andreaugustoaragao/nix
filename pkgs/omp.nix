{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  buildFHSEnv ? null,
}:
let
  version = "19.1.1";
  sources = {
    aarch64-linux = {
      target = "linux-arm64";
      hash = "sha256-8CL3IMSJnrJMbl403LuumK4F9VMrsD6X3/wCz8jdmm8=";
    };
    x86_64-linux = {
      target = "linux-x64";
      hash = "sha256-BOlJD5OU2m1oBEdMwuQes9GPjiYhXfSzS91K1MDYpAE=";
    };
    aarch64-darwin = {
      target = "darwin-arm64";
      hash = "sha256-1aMySs2YN1oBaYobDAGL5Iyu0pVsiqkEStE3/kO8BAA=";
    };
    x86_64-darwin = {
      target = "darwin-x64";
      hash = "sha256-b/7LIqn+AamPkPkaLvBKaXhQojv03eg62tL+gOUag1M=";
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
