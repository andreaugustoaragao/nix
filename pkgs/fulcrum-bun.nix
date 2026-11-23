# Pinned Bun runtime matching Fulcrum's package.json `packageManager` declaration
# so Nix-built web assets and runtime execution match certified development builds
# byte-for-byte.
{
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  unzip,
  openssl,
}:
let
  version = "1.4.2";
  sources = {
    aarch64-linux = {
      asset = "bun-linux-aarch64";
      hash = "sha256-VDKLvC2cjgyfiSxUTWbFeoO4QTnjSQnl7oF1jxrI/ac=";
    };
    x86_64-linux = {
      asset = "bun-linux-x64";
      hash = "sha256-NjaPrvdSeHXV/6UuU81IAhdB8qg+tiCKjdZAaNQiqRM=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "Unsupported system for fulcrum-bun: ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "fulcrum-bun";
  inherit version;

  src = fetchurl {
    url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/${source.asset}.zip";
    inherit (source) hash;
  };

  strictDeps = true;
  nativeBuildInputs = [
    unzip
    autoPatchelfHook
  ];
  buildInputs = [ openssl ];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm 755 ./bun "$out/bin/bun"
    ln -s "$out/bin/bun" "$out/bin/bunx"
    runHook postInstall
  '';

  meta = {
    description = "Bun ${version} pinned to match Fulcrum packageManager";
    mainProgram = "bun";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
