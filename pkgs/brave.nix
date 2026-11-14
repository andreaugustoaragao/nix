{
  callPackage,
  path,
  stdenv,
  ...
}:

let
  version = "1.99.57";
  archives = {
    aarch64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v1.99.57/brave-browser_1.99.57_arm64.deb";
      hash = "sha256-0F30+KjElAdSRoIMF4l6RpYU+HmTindVfwJf2nvmHbQ=";
    };
    x86_64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v1.99.57/brave-browser_1.99.57_amd64.deb";
      hash = "sha256-jNFMV/f9bXnf2aJUUBdbVDihsRtWX/XQitmRtwLen9U=";
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
