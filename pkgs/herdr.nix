{
  lib,
  stdenvNoCC,
  fetchurl,
  fetchFromGitHub,
  makeWrapper,
  bash,
  coreutils,
  python3,
}:

let
  version = "0.9.5";
  sources = {
    aarch64-linux = {
      target = "linux-aarch64";
      hash = "sha256-F9dTby2lCFlSNoDvJ53/ysjkojX05G/o2mwuxEFBiXw=";
    };
    x86_64-linux = {
      target = "linux-x86_64";
      hash = "sha256-FNnovItKngEY13wyJm921GHwm0A0LrI3UpYL2J9Zkp0=";
    };
    aarch64-darwin = {
      target = "macos-aarch64";
      hash = "sha256-+3fCIyoFqANUITgsiUOS9BdOTjihjkivPdApAVfDp+I=";
    };
    x86_64-darwin = {
      target = "macos-x86_64";
      hash = "sha256-X7CpCOx/Z0Xj4kVziwa/rVbEY5HDkas8CVX76tAfE2k=";
    };
  };
  source = sources.${stdenvNoCC.hostPlatform.system};
  integrationSource = fetchFromGitHub {
    owner = "herdrdev";
    repo = "herdr";
    rev = "v${version}";
    hash = "sha256-N7e7oCKxeCoxek6UT8Lweq16rSsQQi34QMb7C2iNpm8=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "herdr";
  inherit version;

  src = fetchurl {
    url = "https://github.com/herdrdev/herdr/releases/download/v${version}/herdr-${source.target}";
    inherit (source) hash;
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/herdr"
    mkdir -p "$out/share/herdr"
    cp -r ${integrationSource}/src/integration/assets "$out/share/herdr/integrations"
    cp -r ${integrationSource}/skills/herdr "$out/share/herdr/skill"
    wrapProgram "$out/bin/herdr" --suffix PATH : ${
      lib.makeBinPath [
        bash
        coreutils
        python3
      ]
    }
    runHook postInstall
  '';

  meta = {
    description = "Terminal workspace for managing AI coding agents";
    homepage = "https://herdr.dev";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "herdr";
  };
}
