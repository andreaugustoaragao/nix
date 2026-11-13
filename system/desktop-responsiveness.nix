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

    # Compress cold anonymous pages in RAM before overflowing to the Btrfs
    # swapfile, avoiding virtual-disk I/O stalls during burst allocations.
    zramSwap = {
      enable = true;
      algorithm = "zstd";
      memoryPercent = 50;
      priority = 100;
    };

    # Kubernetes sets its own CPUWeight for kubepods.slice. Give the
    # desktop session precedence when both are busy, including disk access.
    # Propagate MemoryMin/MemoryLow down to session-*.scope (compositor +
    # interactive windows) and session.slice (audio, DBus, desktop shell) so
    # heavy background work in app.slice / background.slice cannot steal the
    # user slice's reclaim protection under cgroup v2 memory_recursiveprot.
    systemd = {
      slices.user.sliceConfig = {
        CPUWeight = 1000;
        IOWeight = 1000;
        MemoryMin = "2G";
        MemoryLow = "8G";
      };

      units = {
        "user-.slice" = {
          overrideStrategy = "asDropin";
          text = ''
            [Slice]
            CPUWeight=1000
            IOWeight=1000
            MemoryMin=2G
            MemoryLow=8G
          '';
        };
        "session-.scope" = {
          overrideStrategy = "asDropin";
          text = ''
            [Scope]
            CPUWeight=1000
            IOWeight=1000
            MemoryMin=1G
            MemoryLow=6G
          '';
        };
      };

      services = {
        "user@".serviceConfig = {
          Delegate = [
            "pids"
            "memory"
            "cpu"
            "io"
          ];
          MemoryMin = "1G";
          MemoryLow = "2G";
        };

        # Background Nix work competes with the desktop during rebuilds.
        # These weights cover daemon builds and the scheduled auto-upgrade;
        # system/nix.nix also limits builds started directly as root.
        nix-daemon.serviceConfig = {
          CPUWeight = 100;
          IOWeight = 100;
        };
        nixos-upgrade.serviceConfig = {
          CPUWeight = 100;
          IOWeight = 100;
        };
      };

      user = {
        slices = {
          session.sliceConfig = {
            CPUWeight = 1000;
            IOWeight = 1000;
            MemoryMin = "1G";
            MemoryLow = "2G";
          };
          background.sliceConfig = {
            CPUWeight = 50;
            IOWeight = 50;
          };
        };
        units."hc-hold-.service" = {
          overrideStrategy = "asDropin";
          text = ''
            [Service]
            CPUWeight=100
            IOWeight=100
            OOMScoreAdjust=300
          '';
        };
      };
    };

    # Prefer dropping file cache to paging out interactive applications, disable
    # fragmentation-induced kswapd boost storms, and read single swap pages for
    # zram / random heap faults instead of 32 KiB clusters.
    boot.kernel.sysctl = {
      "vm.swappiness" = 10;
      "vm.watermark_boost_factor" = 0;
      "vm.page-cluster" = 0;
    };
  };
}
