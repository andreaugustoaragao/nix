{
  lib,
  fetchFromGitHub,
  makeRustPlatform,
  callPackage,
  git,
  textFallback ? false,
}:

let
  rustToolchain = callPackage ./rust-toolchain.nix { };
  rustPlatform = makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
  # Use importCargoLockStatic (Nix fetchurl via libcurl) rather than
  # fetchCargoVendor (Python 3.13 requests), which fails behind corporate
  # Netskope CA certs lacking an X509v3 Key Usage extension.
  importCargoLockStatic = callPackage ../overlays/import-cargo-lock.nix {
    cargo = rustToolchain;
  };
  src = fetchFromGitHub {
    owner = "Latias94";
    repo = "lspi";
    tag = "v0.2.0";
    hash = "sha256-bWXrDUBJ6SZScuWltEkjqXbcU/WWuzVV308JmsxPFxE=";
  };
in
rustPlatform.buildRustPackage (
  {
    pname = "lspi";
    version = "0.2.0";

    inherit src;

    cargoDeps = importCargoLockStatic {
      lockFile = ./lspi-Cargo.lock;
    };
    cargoBuildFlags = [
      "--package"
      "lspi"
    ];
    cargoTestFlags = [ "--workspace" ];
    nativeCheckInputs = [ git ];

    meta = {
      description = "Language server tools for coding agents over MCP";
      homepage = "https://github.com/Latias94/lspi";
      license = [
        lib.licenses.mit
        lib.licenses.asl20
      ];
      mainProgram = "lspi";
      platforms = lib.platforms.unix;
    };
  }
  // {
    postPatch = ''
      cmp -s Cargo.lock ${./lspi-Cargo.lock} || {
        echo "pkgs/lspi-Cargo.lock does not match upstream lspi source Cargo.lock" >&2
        exit 1
      }
    ''
    + lib.optionalString textFallback ''
      # Cursor currently passes content text to the model but drops structuredContent.
      substituteInPlace crates/lspi-mcp/src/lib.rs \
        --replace-fail 'Ok(r) => Ok(r),' 'Ok(mut r) => {
                  if let Some(ref structured) = r.structured_content {
                      r.content = vec![Content::text(structured.to_string())];
                  }
                  Ok(r)
              },'
    '';
  }
)
