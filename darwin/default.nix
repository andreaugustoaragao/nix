{
  hostName,
  stateVersion,
  owner,
  ...
}:

{
  imports = [
    ./nix.nix
    ./users.nix
    ./packages.nix
    ./homebrew.nix
    ./macos-defaults.nix
    # ./sops.nix
    #   ^ Disabled for first-boot bootstrap on mac-work. secrets.yaml is
    #     not yet re-encrypted to this host's age key, so activation
    #     would fail trying to decrypt. Re-enable after running
    #     `sops updatekeys secrets/secrets.yaml` on a host that holds
    #     an existing admin/tala age key, committing, and pulling here.
    ./certs.nix
  ];

  # Hostname is exposed via networking.hostName under nix-darwin too —
  # the option drives both `scutil --set ComputerName` and
  # `LocalHostName` defaults when paired with `networking.computerName`
  # (which we leave to user-level customization).
  networking.hostName = hostName;

  # System-wide state version pin. Darwin's stateVersion is independent
  # of NixOS' — both live in machines.toml so the same value flows
  # through specialArgs regardless of platform.
  system.stateVersion = 5;

  # nix-darwin >= 24.x requires a primary user to attribute homebrew /
  # GUI activation actions to. We always run with a single human user.
  system.primaryUser = owner.name;

  # Common locale + timezone, matching system/default.nix.
  time.timeZone = "America/Denver";

  # stateVersion lives in the NixOS-side as `system.stateVersion` but
  # on Darwin we keep the schema-version pin (above) and surface the
  # release pin through this string so machines.toml stays the single
  # source of truth.
  system.configurationRevision = null;
  system.darwinLabel = "darwin-${stateVersion}";
}
