{ callPackage, zig, ... }:
callPackage ./sources/vereda-package.nix {
  inherit zig;
  veredaSource = builtins.path {
    name = "vereda-source.tar.gz";
    path = ./sources/vereda-source.tar.gz;
  };
  lockFile = ./sources/vereda-Cargo.lock;
}
