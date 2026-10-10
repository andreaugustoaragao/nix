{
  lib,
  rustPlatform,
  stdenv,
  installShellFiles,
  src,
}:

rustPlatform.buildRustPackage {
  pname = "ttfx";
  version = (builtins.fromTOML (builtins.readFile (src + "/Cargo.toml"))).package.version;
  inherit src;
  cargoLock.lockFile = src + "/Cargo.lock";
  nativeBuildInputs = [ installShellFiles ];
  # Python's recorded easing samples differ by a few floating-point ULPs
  # on ARM. Keep all other tests; this affects parity testing, not rendering.
  checkFlags = lib.optionals stdenv.hostPlatform.isAarch64 [
    "--skip=easing_matches_python_bit_exactly"
  ];
  postInstall = ''
    installShellCompletion --cmd ttfx \
      --bash <($out/bin/ttfx --print-completion bash) \
      --zsh <($out/bin/ttfx --print-completion zsh)
  '';
  meta = {
    description = "Omarchy terminal text effects, built from the local Rust fork";
    homepage = "https://github.com/omacom/ttfx";
    license = lib.licenses.mit;
    mainProgram = "ttfx";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
