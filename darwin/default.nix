{
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
    ./power.nix
    ./caffeinate.nix
    ./sops.nix
    ./certs.nix
    ./auto-upgrade.nix
    ./services
  ];

  # `networking.hostName` under nix-darwin drives `scutil --set
  # ComputerName/HostName/LocalHostName`. On this machine the asset
  # tag G7CH2W2XYR is owned by IT (Jamf re-enforces ComputerName), so
  # we pin the scutil names to the asset tag and keep `mac-work` only
  # as the flake-attribute (`darwin-rebuild switch --flake .#mac-work`)
  # and as the SSH alias resolved via `/etc/hosts` on the dev VMs.
  networking.hostName = "G7CH2W2XYR";

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
