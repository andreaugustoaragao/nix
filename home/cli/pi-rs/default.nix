# pi-rs: single-binary toolbox of high-performance, context-aware primitives
# for pi-coding-agent extensions.
#
# The binary exposes subcommands: hash, grep, summary, html2md, ast-grep
# (stub), ast-edit (stub). Each TS extension shells out to the appropriate
# subcommand; the binary path is pinned at build time so no PATH dependency.
{ lib, rustPlatform, ... }:
rustPlatform.buildRustPackage {
  pname = "pi-rs";
  version = "0.1.0";

  src = builtins.path {
    name = "pi-rs-source";
    path = ./.;
    # Filter out the target/ build directory and other ephemera so the
    # store path is reproducible. Everything else (Cargo.toml, Cargo.lock,
    # crates/, bigrams.json) is included verbatim.
    filter =
      path: type:
      let
        rel = lib.removePrefix (toString ./. + "/") (toString path);
      in
      !(lib.hasPrefix "target" rel) && !(lib.hasPrefix ".git" rel);
  };

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  # No build-time tools needed beyond what buildRustPackage provides; all
  # native deps (tree-sitter grammars, ripgrep crates) build pure-Rust.

  doCheck = false; # Hashline unit tests are pure-logic; covered out-of-band.

  meta = {
    description = "High-performance primitives for pi-coding-agent extensions";
    homepage = "https://github.com/aragao/nix";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "pi-rs";
  };
}
