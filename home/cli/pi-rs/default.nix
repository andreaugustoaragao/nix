# pi-rs: single-binary toolbox of high-performance, context-aware primitives
# for pi-coding-agent extensions.
#
# The binary exposes subcommands: hash, grep, summary, html2md, ast-grep,
# ast-edit. Each TS extension shells out to the appropriate subcommand;
# the binary path is pinned at build time so no PATH dependency.
# Tests for the AST orchestration live in `cmd::ast::tests` and run as
# part of `cargo test` in the workspace; integration is covered by the
# extension layer.
{
  lib,
  makeRustPlatform,
  callPackage,
  git,
  ...
}:

let
  rustToolchain = callPackage ../../../pkgs/rust-toolchain.nix { };
  rustPlatform = makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
  # Local copy of nixpkgs's importCargoLock with the default crates.io
  # URL swapped for static.crates.io — crates.io/api/v1 now 403s under
  # curl's default user-agent. See overlays/import-cargo-lock.nix.
  importCargoLockStatic = callPackage ../../../overlays/import-cargo-lock.nix {
    cargo = rustToolchain;
  };
in
rustPlatform.buildRustPackage {
  pname = "pi-rs";
  version = "0.3.0";

  src = builtins.path {
    name = "pi-rs-source";
    path = ./.;
    # Filter out the target/ build directory and other ephemera so the
    # store path is reproducible. Everything else (Cargo.toml, Cargo.lock,
    # crates/, bigrams.json) is included verbatim.
    filter =
      path: _type:
      let
        rel = lib.removePrefix (toString ./. + "/") (toString path);
      in
      !(lib.hasPrefix "target" rel) && !(lib.hasPrefix ".git" rel);
  };

  cargoDeps = importCargoLockStatic {
    lockFile = ./Cargo.lock;
  };

  nativeCheckInputs = [ git ];
  doCheck = true;
  cargoTestFlags = [ "--workspace" ];

  # Materialize the per-agent hook shims under $out/share/pi-rs/agent-hooks/
  # with the absolute /nix/store path of the pi-rs binary substituted in.
  # Home-manager modules for claude/cursor/codex/pi reference these.
  postInstall = ''
    mkdir -p $out/share/pi-rs/agent-hooks

    substitute ${./agent-hooks/claude-rewrite.sh.in} \
      $out/share/pi-rs/agent-hooks/claude-rewrite.sh \
      --replace-fail @pi-rs@ $out/bin/pi-rs
    substitute ${./agent-hooks/cursor-rewrite.sh.in} \
      $out/share/pi-rs/agent-hooks/cursor-rewrite.sh \
      --replace-fail @pi-rs@ $out/bin/pi-rs

    chmod +x $out/share/pi-rs/agent-hooks/*.sh

    # codex-rules.md and the pi extension are copied verbatim (the
    # extension's PI_RS placeholder is substituted by home/cli/pi.nix).
    cp ${./agent-hooks/codex-rules.md} $out/share/pi-rs/agent-hooks/codex-rules.md
    cp ${./agent-hooks/pi-rewrite-extension.ts} \
      $out/share/pi-rs/agent-hooks/pi-rewrite-extension.ts
  '';

  meta = {
    description = "High-performance primitives for pi-coding-agent extensions";
    homepage = "https://github.com/aragao/nix";
    license = [
      lib.licenses.mit
      lib.licenses.asl20
    ];
    platforms = lib.platforms.unix;
    mainProgram = "pi-rs";
  };
}
