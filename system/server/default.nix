{ lib, hostName, ... }:

{
  # Auth stack temporarily skipped — sops secrets in secrets.yaml are
  # still placeholders ("TBD"). authelia crash-loops on the fake
  # jwt_private_key and ACME can't issue without a real Cloudflare
  # token. Re-enable each module once its secret values are real.
  imports = [
    ./netwatch.nix
    ./authentik.nix
    ./immich.nix
    ./immich-oidc.nix
    ./logging.nix
    ./monitoring.nix
    # ./acme.nix
    # ./caddy.nix
    # ./lldap.nix
    # ./authelia.nix
  ];

  services.faragao-netwatch.enable = lib.mkIf (hostName == "tala") true;
  services.faragao-authentik.enable = lib.mkIf (hostName == "tala") true;
  services.faragao-logging.enable = lib.mkIf (hostName == "tala") true;
}
