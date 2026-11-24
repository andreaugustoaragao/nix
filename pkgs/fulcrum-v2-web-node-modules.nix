# Cached Fixed-Output Derivation for Fulcrum v2 React + @ui-sdk/react frontend node_modules.
# Keyed strictly on v2/web/package.json and v2/web/bun.lock so app source changes hit cache in 0s.
{
  lib,
  stdenv,
  callPackage,
  cacert,
  src,
  fulcrumBun ? callPackage ./fulcrum-bun.nix { },
  fodHashes ? builtins.fromJSON (builtins.readFile ./fulcrum-v2-web-node-modules-hash.json),
}:
let
  srcRoot = toString src;
  webDepsSrc = builtins.path {
    name = "fulcrum-v2-web-deps-src";
    path = src;
    filter =
      path: _type:
      let
        rel = lib.removePrefix "${srcRoot}/" path;
      in
      rel == "v2" || rel == "v2/web" || rel == "v2/web/package.json" || rel == "v2/web/bun.lock";
  };
  outputHash =
    fodHashes.${stdenv.hostPlatform.system}
      or (throw "Unsupported system for fulcrum-v2-web-node-modules: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "fulcrum-v2-web-node-modules";
  version = "1";
  src = webDepsSrc;

  nativeBuildInputs = [
    fulcrumBun
    cacert
  ];

  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  inherit outputHash;

  dontConfigure = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR/home"
    export BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
    export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
    mkdir -p "$HOME" "$BUN_INSTALL_CACHE_DIR"
    cd v2/web
    bun install --frozen-lockfile --no-progress
    rm -rf node_modules/.cache
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a node_modules "$out/node_modules"
    runHook postInstall
  '';
}
