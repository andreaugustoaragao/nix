{
  lib,
  hostName,
  ...
}:

{
  config = lib.mkIf (hostName == "prl-dev-vm") {
    # This VM runs development checks and Kubernetes alongside video calls.
    # Keeping temporary build output on disk prevents /tmp from consuming RAM.
    boot.tmp.useTmpfs = lib.mkForce false;

    # Kubernetes sets its own CPUWeight for kubepods.slice. Give the
    # desktop session precedence when both are busy, including disk access.
    systemd.slices.user.sliceConfig = {
      CPUWeight = 1000;
      IOWeight = 1000;
      # Keep the graphical session reclaimable only after other workloads.
      # MemoryMin protects its first 2 GiB even under severe pressure;
      # MemoryLow gives browsers and calls room to stay responsive.
      MemoryMin = "2G";
      MemoryLow = "8G";
    };

    # Background Nix work competes with the desktop during rebuilds.
    # These weights cover daemon builds and the scheduled auto-upgrade;
    # system/nix.nix also limits builds started directly as root.
    systemd.services.nix-daemon.serviceConfig = {
      CPUWeight = 100;
      IOWeight = 100;
    };
    systemd.services.nixos-upgrade.serviceConfig = {
      CPUWeight = 100;
      IOWeight = 100;
    };

    # Prefer dropping file cache to paging out interactive applications.
    boot.kernel.sysctl."vm.swappiness" = 10;
  };
}
