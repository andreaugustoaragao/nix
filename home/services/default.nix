{
  lib,
  hostName,
  isDarwinHost ? false,
  ...
}:

# Platform-gated user services. The Linux entries below are all
# systemd-user-flavored (notes-sync, fulcrum, darkman, local-llm) and
# would error at evaluation on Darwin where `systemd.user.services` is
# undefined. The Darwin notes-sync is a structurally separate launchd
# agent in notes-sync-darwin.nix.
{
  imports =
    lib.optionals (!isDarwinHost) [
      ./notes-sync.nix
      ./fulcrum.nix
      ./darkman.nix
    ]
    ++ lib.optionals isDarwinHost [
      ./notes-sync-darwin.nix
    ]
    ++ lib.optionals (hostName == "workstation") [
      ./local-llm.nix
    ];
}
