# Nix package derivation for Fulcrum Vault v2 standalone Rust binaries:
#   - shared-vault       (read-only filesystem overlay daemon, CLI & MCP)
#   - vault-extract      (contained PDF/OOXML/OCR Local Extractor CLI)
#   - ai-task-scheduler  (standalone scheduler with Capability Profiles, CLI & MCP)
#
# Filtered to Cargo.toml, Cargo.lock, and services/ so TypeScript-only Fulcrum
# releases hit the Nix store cache in 0s without recompiling Rust.
{
  lib,
  pkgs,
  src,
  onnxruntimeLib ? "${pkgs.onnxruntime}/lib/libonnxruntime.so",
}:
let
  rustToolchain = pkgs.callPackage ./rust-toolchain.nix { };
  rustPlatform = pkgs.makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
  srcRoot = toString src;
  rustSrc = builtins.path {
    name = "fulcrum-rust-src";
    path = src;
    filter =
      path: _type:
      let
        rel = lib.removePrefix "${srcRoot}/" path;
      in
      rel == "Cargo.toml" || rel == "Cargo.lock" || rel == "services" || lib.hasPrefix "services/" rel;
  };
  runtimeLibs = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.openssl
  ];
in
rustPlatform.buildRustPackage {
  pname = "fulcrum-vault-v2";
  # Keep crate workspace version independent of package.json so TS-only
  # Fulcrum version bumps reuse the cached Rust build.
  version = "0.2.0";
  src = rustSrc;

  # Read Cargo.lock from `src` directly so `nix flake check --no-build` works on
  # cold stores where filtered `builtins.path` (`rustSrc`) is not materialized,
  # while keeping `src = rustSrc` so TS-only bumps still hit the Rust build cache.
  cargoLock.lockFileContents = builtins.readFile "${src}/Cargo.lock";
  buildAndTestSubdir = ".";
  cargoBuildFlags = [
    "--workspace"
    "--bins"
  ];
  doCheck = false;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  postInstall = ''
    rm -f "$out/bin/vault-v2-schema-gen"

    wrapProgram "$out/bin/shared-vault" \
      --prefix LD_LIBRARY_PATH : "${runtimeLibs}" \
      --set-default FULCRUM_ONNXRUNTIME_LIBRARY "${onnxruntimeLib}"

    wrapProgram "$out/bin/vault-extract" \
      --set-default FULCRUM_BWRAP_EXEC "${pkgs.bubblewrap}/bin/bwrap" \
      --set-default FULCRUM_PDFTOTEXT_EXEC "${pkgs.poppler-utils}/bin/pdftotext" \
      --set-default FULCRUM_PDFTOPPM_EXEC "${pkgs.poppler-utils}/bin/pdftoppm" \
      --set-default FULCRUM_OCR_EXEC "${pkgs.tesseract}/bin/tesseract" \
      --set-default TESSDATA_PREFIX "${pkgs.tesseract}/share/tessdata"

    wrapProgram "$out/bin/ai-task-scheduler" \
      --set-default FULCRUM_BWRAP_EXEC "${pkgs.bubblewrap}/bin/bwrap"

    ln -s "$out/bin/shared-vault" "$out/bin/vault-service"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    for executable in shared-vault vault-extract ai-task-scheduler; do
      "$out/bin/$executable" --help >/dev/null
    done
    runHook postInstallCheck
  '';

  meta = {
    description = "Fulcrum Vault v2 read-only overlay, contained Local Extractor, and standalone AI Task Scheduler";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
