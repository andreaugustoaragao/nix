{ ... }:

{
  # Auth stack temporarily skipped — sops secrets in secrets.yaml are
  # still placeholders ("TBD"). authelia crash-loops on the fake
  # jwt_private_key and ACME can't issue without a real Cloudflare
  # token. Re-enable each module once its secret values are real.
  imports = [
    # ./acme.nix
    # ./caddy.nix
    # ./lldap.nix
    # ./authelia.nix
  ];
}
