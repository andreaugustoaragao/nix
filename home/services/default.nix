{
  lib,
  hostName,
  isDarwinHost ? false,
  isServer ? false,
  ...
}:

# Platform-gated user services. The Linux entries below are all
# systemd-user-flavored (notes-sync, fulcrum, darkman, local-llm) and
# would error at evaluation on Darwin where `systemd.user.services` is
# undefined. The Darwin notes-sync is a structurally separate launchd
# agent in notes-sync-darwin.nix.
#
# fulcrum is additionally gated to non-server hosts: its systemd
# unit unconditionally reads /run/secrets/anthropic_api_key, and that
# secret is declared `lib.optionalAttrs (!isServer)` in system/sops.nix,
# so loading fulcrum on the `server` profile (tala) blows up at eval.
{
  imports =
    lib.optionals (!isDarwinHost) [
      ./notes-sync.nix
      ./darkman.nix
    ]
    ++ lib.optionals (!isDarwinHost && !isServer) [
      ./fulcrum.nix
    ]
    ++ lib.optionals isDarwinHost [
      ./notes-sync-darwin.nix
    ]
    ++ lib.optionals (hostName == "workstation") [
      ./local-llm.nix
    ];
}
