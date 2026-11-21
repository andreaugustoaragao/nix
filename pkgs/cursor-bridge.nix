{
  lib,
  makeRustPlatform,
  callPackage,
  pkg-config,
  openssl,
}:

let
  rustToolchain = callPackage ./rust-toolchain.nix { };
  rustPlatform = makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
in
rustPlatform.buildRustPackage {
  pname = "cursor-bridge";
  version = "0.1.0";

  src = ./cursor-bridge;

  cargoLock.lockFile = ./cursor-bridge/Cargo.lock;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  meta = {
    description = "Carry lan-mouse input both ways over one QUIC connection";
    license = lib.licenses.mit;
    mainProgram = "cursor-bridge";
    platforms = lib.platforms.linux;
  };
}
