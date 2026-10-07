{ config, lib, ... }:

let
  optionalFingerprint = lib.types.nullOr (lib.types.strMatching "[A-F0-9]{64}");
  runtimeDirectory = "${config.xdg.dataHome}/fulcrum/certs/local-ca-v1";
in
{
  options.my.fulcrum.localTls = {
    enable = lib.mkEnableOption "the explicitly staged Fulcrum desktop-only local CA migration";
    caCertificate = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Public CA certificate only. This file enters the Nix store; never supply a private key.";
    };
    caSha256 = lib.mkOption {
      type = optionalFingerprint;
      default = null;
      description = "Reviewed uppercase SHA-256 DER fingerprint of the dedicated public CA.";
    };
    serverSha256 = lib.mkOption {
      type = optionalFingerprint;
      default = null;
      description = "Reviewed uppercase SHA-256 DER fingerprint of the CA:false server certificate.";
    };
    serverCertificate = lib.mkOption {
      type = lib.types.strMatching "/.+";
      description = "Runtime certificate path in the staged release directory; not read during Nix evaluation.";
    };
    serverKey = lib.mkOption {
      type = lib.types.strMatching "/.+";
      description = "Runtime private-key path; the key must never enter the Nix store.";
    };
    desktopPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Pinned, verified Fulcrum Desktop package to wrap with app-process-only CA trust.";
    };
  };
  config.my.fulcrum.localTls = {
    serverCertificate = lib.mkDefault "${runtimeDirectory}/localhost.pem";
    serverKey = lib.mkDefault "${runtimeDirectory}/localhost-key.pem";
  };
}
