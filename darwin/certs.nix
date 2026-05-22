{ pkgs, ... }:

let
  # Corporate internal CAs + the MITM TLS-intercepting proxy root.
  # NixOS uses `security.pki.certificateFiles` (which writes
  # /etc/ssl/certs and is picked up by openssl, curl, git, etc.).
  # Darwin has no such option — system trust lives in the macOS
  # keychain, and corporate MDM usually pushes these CAs there
  # already. This module covers the *user-space* tooling (nix-managed
  # git/curl/etc.) by exporting SSL_CERT_FILE pointing at a bundle
  # that contains the corporate certs in addition to the system CA
  # store.
  certs = [
    ../certs/internal-root-2.pem
    ../certs/internal-root-1.pem
    ../certs/internal-intermediate.pem
    ../certs/proxy-root.pem
  ];

  bundle = pkgs.runCommand "corp-ca-bundle.pem" { } ''
    cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ${builtins.concatStringsSep " " (map toString certs)} > $out
  '';
in
{
  # Make the bundle available system-wide so curl/git/etc. trust the
  # corporate CAs without per-user setup. macOS GUI apps still use
  # the system keychain.
  environment.variables = {
    SSL_CERT_FILE = "${bundle}";
    NIX_SSL_CERT_FILE = "${bundle}";
    GIT_SSL_CAINFO = "${bundle}";
    CURL_CA_BUNDLE = "${bundle}";
  };
}
