# Pinned Trivy 0.74.0 binary matching Fulcrum's exact scanner gate
# (scripts/trivy-version.sh + scripts/run-trivy.sh require `Version: 0.74.0`;
# nixpkgs stable ships 0.72.0 and unstable ships 0.76.2).
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "0.74.0";
  sources = {
    x86_64-linux = {
      platform = "Linux-64bit";
      sha256 = "2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a";
    };
    aarch64-linux = {
      platform = "Linux-ARM64";
      sha256 = "b94ce1976bbf3c15b514b605ee88be7c6d94a29be2302847ff01cb794d47aad5";
    };
    x86_64-darwin = {
      platform = "macOS-64bit";
      sha256 = "472816f6888dda689d075c30254d4210b4d1035acf365aa72332f584c2f60485";
    };
    aarch64-darwin = {
      platform = "macOS-ARM64";
      sha256 = "1caada5e0e2091909357c7525d3aa76f4b660b13821bc143b190c7483e31cc11";
    };
  };
  source = sources.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation {
  pname = "trivy";
  inherit version;

  src = fetchurl {
    url = "https://github.com/aquasecurity/trivy/releases/download/v${version}/trivy_${version}_${source.platform}.tar.gz";
    inherit (source) sha256;
  };

  sourceRoot = ".";
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 trivy "$out/bin/trivy"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    version_line="$("$out/bin/trivy" --version | head -n 1)"
    test "$version_line" = "Version: ${version}"
  '';

  meta = {
    description = "Simple and comprehensive vulnerability scanner for containers and other artifacts";
    homepage = "https://trivy.dev";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "trivy";
  };
}
