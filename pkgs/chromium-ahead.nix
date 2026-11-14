{ lib, chromium }:

let
  # Drop this fallback after nixpkgs-unstable reaches Chromium 157.0.8103.78.
  releaseInfo = builtins.fromJSON (
    builtins.readFile (
      builtins.fetchurl {
        url = "https://raw.githubusercontent.com/NixOS/nixpkgs/d9da0c26ac22e30ce194310bac9a39bbbba8b638/pkgs/applications/networking/browsers/chromium/info.json";
        sha256 = "sha256-9NcSefo6zBQ9v2yAIA3Bb/DEKuK71a4oXiq33sL5RqU=";
      }
    )
  );
in
if lib.versionOlder chromium.version "157.0.8103.78" then
  chromium.override { upstream-info = releaseInfo.chromium; }
else
  chromium
