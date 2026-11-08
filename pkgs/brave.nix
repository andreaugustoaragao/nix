{
  callPackage,
  path,
  stdenv,
  ...
}:

let
  version = "1.99.55";
  archives = {
    aarch64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v1.99.55/brave-browser_1.99.55_arm64.deb";
      hash = "sha256-r5nwaDDQllA/Zmezb/btbEVf7vUgPw0o/vTP065e4Qo=";
    };
    x86_64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v1.99.55/brave-browser_1.99.55_amd64.deb";
      hash = "sha256-Nk6VSirYTVuj4OIXoinVhzxK5xB9FeYSDkIHUpU5yI0=";
    };
  };
in
# Use the pinned packaging helper without evaluating the removed brave attribute.
callPackage (path + "/pkgs/by-name/br/brave/make-brave.nix") { } (
  {
    pname = "brave";
    inherit version;
  }
  // archives.${stdenv.hostPlatform.system}
)
