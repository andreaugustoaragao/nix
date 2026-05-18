{ pkgs, ... }:

let
  # Avaya + Zscaler internal CAs. NixOS uses
  # `security.pki.certificateFiles` (which writes /etc/ssl/certs and
  # is picked up by openssl, curl, git, etc.). Darwin has no such
  # option — system trust lives in the macOS keychain, and IT MDM
  # usually pushes these CAs there already. This module covers the
  # *user-space* tooling (nix-managed git/curl/etc.) by exporting
  # SSL_CERT_FILE pointing at a bundle that contains the Avaya certs
  # in addition to the system CA store.
  certs = [
    ../certs/avayaitrootca2.pem
    ../certs/avayaitrootca.pem
    ../certs/avayaitserverca2.pem
    ../certs/zscalerrootcertificate-2048-sha256.pem
  ];

  bundle = pkgs.runCommand "avaya-ca-bundle.pem" { } ''
    cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ${builtins.concatStringsSep " " (map toString certs)} > $out
  '';
in
{
  # Make the bundle available system-wide so curl/git/etc. trust the
  # Avaya CAs without per-user setup. macOS GUI apps still use the
  # system keychain.
  environment.variables = {
    SSL_CERT_FILE = "${bundle}";
    NIX_SSL_CERT_FILE = "${bundle}";
    GIT_SSL_CAINFO = "${bundle}";
    CURL_CA_BUNDLE = "${bundle}";
  };
}
