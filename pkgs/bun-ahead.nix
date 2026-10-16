# Bun pinned ahead of nixpkgs. Both the locked nixpkgs and nixos-unstable HEAD
# still ship 1.4.2 (checked 2026-10-16), while oven-sh releases 1.4.3. Modeled
# on nixpkgs' pkgs/by-name/bu/bun/package.nix build; bumped to 1.4.3 with
# freshly computed hashes. Drop this file once nixpkgs unstable packages a
# version >= 1.4.3.
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  unzip,
  installShellFiles,
  makeWrapper,
  openssl,
  cctools,
  darwin,
  rcodesign,
}:

let
  version = "1.4.3";
  # Three platforms cover every host in machines.toml (workstation/tala,
  # prl/vm dev VMs, mac-work). x86_64-darwin is intentionally absent: the
  # upstream baseline build requires AVX2 and no darwin-x64 host is managed.
  sources = {
    aarch64-linux = {
      asset = "bun-linux-aarch64";
      hash = "sha256-76mBPaXtckI7+Ef5FujSxHwNd2rdlyNUAmp14Q2pqiE=";
    };
    x86_64-linux = {
      asset = "bun-linux-x64";
      hash = "sha256-PnMFKNiXdfA/h/BcBnh8TfQJnQo38/JS57gpyyOBbhg=";
    };
    aarch64-darwin = {
      asset = "bun-darwin-aarch64";
      hash = "sha256-gK/UwGm0am+o8+xSC+vHUKeEPkqNW5WD0prUNsAKNAM=";
    };
    # x86_64-darwin kept as an explicit throw rather than an entry so the
    # source set maps 1:1 onto supported machines.
  };
  source = sources.${stdenvNoCC.hostPlatform.system};
in

stdenvNoCC.mkDerivation {
  pname = "bun";
  inherit version;

  src = fetchurl {
    url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/${source.asset}.zip";
    inherit (source) hash;
  };

  strictDeps = true;
  nativeBuildInputs = [
    unzip
    installShellFiles
    makeWrapper
  ]
  ++ lib.optionals stdenvNoCC.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = [ openssl ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm 755 ./bun $out/bin/bun
    ln -s $out/bin/bun $out/bin/bunx
    runHook postInstall
  '';

  # Keep the packaged executable intact; on macOS point libicucore at the
  # nixpkgs ICU (the sandbox has no /usr/lib) and re-sign.
  postPhases = [ "postPatchelf" ];
  postPatchelf =
    lib.optionalString stdenvNoCC.hostPlatform.isDarwin ''
      '${lib.getExe' cctools "${cctools.targetPrefix}install_name_tool"}' $out/bin/bun \
        -change /usr/lib/libicucore.A.dylib '${lib.getLib darwin.ICU}/lib/libicucore.A.dylib'
      '${lib.getExe rcodesign}' sign --code-signature-flags linker-signed $out/bin/bun
    ''
    # Completion generation runs bun itself, so it only works when the build
    # machine can execute the target binary.
    + lib.optionalString (stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform) ''
      installShellCompletion --cmd bun \
        --bash <(SHELL="bash" $out/bin/bun completions) \
        --zsh <(SHELL="zsh" $out/bin/bun completions) \
        --fish <(SHELL="fish" $out/bin/bun completions)
    '';

  meta = {
    description = "Incredibly fast JavaScript runtime, bundler, transpiler and package manager (pinned 1.4.3)";
    homepage = "https://bun.sh";
    changelog = "https://bun.sh/blog/bun-v${version}";
    license = with lib.licenses; [
      mit
      lgpl21Only
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "bun";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
      "aarch64-darwin"
    ];
    # Upstream binary is broken on musl (nixpkgs#280716).
    broken = stdenvNoCC.hostPlatform.isMusl;
  };
}
