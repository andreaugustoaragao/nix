{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  ripgrep,
  sysctl,
}:

let
  version = "2.0.18";
  # Upstream moved v2 to @opencode/cli; nixpkgs.opencode still tracks v1.
  # Use baseline x64 builds so AVX2 is not required on older hosts.
  sources = {
    aarch64-linux = {
      target = "linux-arm64";
      hash = "sha256-3cmOXHicSW2toez66f5OCTHHrEOkbaVDa5fs2lzQul0=";
    };
    x86_64-linux = {
      target = "linux-x64-baseline";
      hash = "sha512-yR7tA8ZAjUzUV3vcBIV1z/zp7KPNV55XQipP9qsQppEApyEv7/NJOIaPK8n+yFl7kogPRk1fQ0fsOW+4KO7mbQ==";
    };
    aarch64-darwin = {
      target = "darwin-arm64";
      hash = "sha512-GRJMkkyQKDPIJbYr2WtFTgK1Vb1p/4xrqxgXA/TLyJ1Tn5tK5hNOtbslUZgsktrEQD6TeT5bVZcjRLC41n+d/A==";
    };
    x86_64-darwin = {
      target = "darwin-x64-baseline";
      hash = "sha512-OPKQFskBfK8nKSOxqX4Vd3OtTbEDtgCSOPLi+nnGxZI6WJ20Rt2lOI4NVpwxxaX8tPAaiZB/gYEqmkmGjNsYBQ==";
    };
  };
  source = sources.${stdenv.hostPlatform.system};
in
stdenv.mkDerivation {
  pname = "opencode2";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@opencode/cli-${source.target}/-/cli-${source.target}-${version}.tgz";
    inherit (source) hash;
  };

  nativeBuildInputs = [
    makeWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  dontConfigure = true;
  dontBuild = true;
  # The Bun executable includes its application payload; preserve it intact.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/opencode "$out/libexec/opencode2/opencode"
    makeWrapper "$out/libexec/opencode2/opencode" "$out/bin/opencode2" \
      --prefix PATH : ${
        lib.makeBinPath ([ ripgrep ] ++ lib.optionals stdenv.hostPlatform.isDarwin [ sysctl ])
      } \
      --set OPENCODE_DISABLE_AUTOUPDATE true
    runHook postInstall
  '';

  meta = {
    description = "OpenCode v2 AI coding agent (opencode2 command)";
    homepage = "https://opencode.ai";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames sources;
    mainProgram = "opencode2";
  };
}
