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

  # Auto-rename any plain /etc file we're about to take over so
  # nix-darwin's etcChecks safety net can proceed without an operator
  # in the loop. Idempotent: skips files that are already symlinks
  # (nix-managed) or have an existing backup, so subsequent rebuilds
  # are no-ops here.
  #
  # NOTE: we deliberately do NOT use the `.before-nix-darwin` suffix
  # the error message suggests — nix-darwin's `configuring networking`
  # phase has a vestigial "restoring /etc/hosts..." block that
  # auto-moves `/etc/hosts.before-nix-darwin` back to `/etc/hosts` at
  # the END of activation, which would undo the takeover on every
  # rebuild. `.pre-nix` is invisible to that block.
  system.activationScripts.preActivation.text = ''
    backup_untracked() {
      local f="$1"
      if [ -e "$f" ] && [ ! -L "$f" ] && [ ! -e "$f.pre-nix" ]; then
        echo "[preActivation] backing up untracked $f -> $f.pre-nix"
        mv "$f" "$f.pre-nix"
      fi
    }
    backup_untracked /etc/hosts
  '';

  # Static /etc/hosts entries for the Parallels + VMware dev VMs.
  # Replaces mDNS/Bonjour resolution (the rest of the flake dropped
  # avahi to avoid the Docker/CNI multicast echo / conflict-rename
  # loop on the VMs). Both short and `.local` forms are listed so
  # any URL that still uses `<host>.local` keeps working.
  #
  # nix-darwin's `environment.etc."hosts".text` replaces /etc/hosts
  # wholesale, so the macOS default localhost/broadcasthost entries
  # are preserved here verbatim.
  environment.etc."hosts".text = ''
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1       localhost
    255.255.255.255 broadcasthost
    ::1             localhost

    # Dev VMs hosted on this laptop.
    10.211.55.4     prl-dev-vm prl-dev-vm.local
    192.168.150.5   vmw-dev-vm vmw-dev-vm.local
  '';

  # stateVersion lives in the NixOS-side as `system.stateVersion` but
  # on Darwin we keep the schema-version pin (above) and surface the
  # release pin through this string so machines.toml stays the single
  # source of truth.
  system.configurationRevision = null;
  system.darwinLabel = "darwin-${stateVersion}";
}
