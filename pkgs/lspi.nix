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
in
rustPlatform.buildRustPackage (
  {
    pname = "lspi";
    version = "0.2.0";

    src = fetchFromGitHub {
      owner = "Latias94";
      repo = "lspi";
      tag = "v0.2.0";
      hash = "sha256-bWXrDUBJ6SZScuWltEkjqXbcU/WWuzVV308JmsxPFxE=";
    };

    cargoHash = "sha256-uKCa1ZMBmIMr/c0h6Cvb0xRJadL/rQXdm8WBTZL8zqY=";
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
  // lib.optionalAttrs textFallback {
    # Cursor currently passes content text to the model but drops structuredContent.
    postPatch = ''
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
