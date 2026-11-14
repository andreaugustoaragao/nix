{
  lib,
  callPackage,
  fetchgit,
  makeRustPlatform,
  pkg-config,
  makeWrapper,
  wayland,
  libxkbcommon,
  vulkan-loader,
  mesa,
  libGL,
  libglvnd,
  libx11,
  libxcursor,
  libxi,
  libxrandr,
}:
let
  version = "0.1.0";
  rev = "cd9b7c0221554ac96bee52cd3e1d85e45ddb0403";
  rustToolchain = callPackage ./rust-toolchain.nix { };
  rustPlatform = makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
  # Same pin and hash as vitals/nix/rune-source.nix at `rev`.
  runeSource = fetchgit {
    name = "rune-7ead7d6";
    url = "https://github.com/anomalyco/rune";
    rev = "7ead7d63fcf6f9dd9669385a8b90e2ae80015d7b";
    hash = "sha256-e6f1kr0qvTT13YKZIGhiFee33RwydeVX60Yz23j/cQA=";
    fetchSubmodules = true;
  };
  libraries = [
    wayland
    libxkbcommon
    vulkan-loader
    mesa
    libGL
    libglvnd
    libx11
    libxcursor
    libxi
    libxrandr
  ];
in
rustPlatform.buildRustPackage {
  pname = "vitals";
  inherit version;
  passthru.sourceRevision = rev;

  # `rev` is the git commit this tarball was archived from. The repository
  # is private, so the bytes live in the flake instead of a GitHub fetch.
  # Replace the tarball from that commit when bumping `rev`:
  # `git -C <vitals> archive --format=tar.gz --prefix=vitals/ <rev>`.
  src = ./vitals-source.tar.gz;

  cargoLock.lockFile = ./vitals-Cargo.lock;

  postPatch = ''
    cp -a ${runeSource} .rune-source
    chmod -R u+w .rune-source
    patch -d .rune-source -p1 < nix/rune-virgl.patch
  '';

  nativeBuildInputs = [
    pkg-config
    makeWrapper
  ];
  buildInputs = libraries;

  doCheck = false;

  postInstall = ''
    wrapProgram "$out/bin/vitals" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath libraries}"
  '';

  meta = {
    description = "Native Linux system monitor built on Anomaly Rune";
    homepage = "https://github.com/andrearagao/vitals";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "vitals";
  };
}
