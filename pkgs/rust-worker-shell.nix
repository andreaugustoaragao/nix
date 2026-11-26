{
  pkgs,
}:
pkgs.mkShell {
  packages = [
    (pkgs.callPackage ./rust-toolchain.nix { })
    pkgs.pkg-config
    pkgs.cmake
    pkgs.gnumake
    pkgs.sccache
  ];
  buildInputs = [
    pkgs.openssl
    pkgs.zlib
  ];
  RUSTC_WRAPPER = "${pkgs.sccache}/bin/sccache";
  CARGO_INCREMENTAL = "0";
}
