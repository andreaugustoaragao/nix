# Nix package derivation for Fulcrum Vault v2 standalone Rust binaries:
#   - shared-vault       (read-only filesystem overlay daemon, CLI & MCP)
#   - vault-extract      (contained PDF/OOXML/OCR Local Extractor CLI)
#   - ai-task-scheduler  (standalone scheduler with Capability Profiles, CLI & MCP)
#
# Replaces the legacy Bun vault-service, shared-vault-grammar, and ChromaDB stack
# per docs/adr/0001..0004.
{
  lib,
  pkgs,
  src,
  onnxruntimeLib ? "${pkgs.onnxruntime}/lib/libonnxruntime.so",
}:
let
  runtimeLibs = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.openssl
  ];
in
pkgs.rustPlatform.buildRustPackage {
  pname = "fulcrum-vault-v2";
  version = "0.2.0";
  inherit src;

  cargoLock.lockFile = "${src}/Cargo.lock";
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
  '';

  meta = {
    description = "Fulcrum Vault v2 read-only overlay, contained Local Extractor, and standalone AI Task Scheduler";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
