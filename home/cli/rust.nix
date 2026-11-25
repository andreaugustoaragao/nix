{
  config,
  lib,
  pkgs,
  hostName,
  ...
}:

let
  rustToolchain = pkgs.callPackage ../../pkgs/rust-toolchain.nix { };
  rustcTarget = pkgs.stdenv.hostPlatform.rust.rustcTarget;

  # Use target.<triple>.linker instead of target.<triple>.rustflags because
  # Cargo treats target-level rustflags and project [build].rustflags as
  # mutually exclusive (suppressing project flags like Vitals' -L path).
  moldCc = pkgs.writeShellScriptBin "mold-cc" ''
    exec ${pkgs.stdenv.cc}/bin/cc -B${pkgs.mold}/bin -fuse-ld=mold "$@"
  '';
  rustStorageGc = pkgs.writeShellApplication {
    name = "rust-storage-gc";
    runtimeInputs = [
      rustToolchain
      pkgs.cargo-cache
      pkgs.duperemove
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail

      # /home/aragao is mounted noatime, so `cargo sweep --time` cannot tell
      # recently read fingerprints from stale ones. Keep the automated job
      # safe: prune re-extractable Cargo checkouts and deduplicate identical
      # Btrfs extents across worktrees.
      projects_dir="${config.home.homeDirectory}/projects"
      cache_dir="${config.xdg.cacheHome}"
      mkdir -p "$cache_dir"

      cargo cache --autoclean || true

      if [[ -d "$projects_dir" ]]; then
        duperemove -rdh --hashfile="$cache_dir/duperemove-projects.hash" "$projects_dir" || true
      fi
    '';
  };
in
{
  config = lib.mkIf (hostName == "prl-dev-vm") {
    home = {
      packages = [
        pkgs.mold
        pkgs.cargo-sweep
        pkgs.cargo-cache
        pkgs.duperemove
        rustStorageGc
      ];

      file.".cargo/config.toml".text = ''
        [build]
        rustc-wrapper = "${lib.getExe pkgs.sccache}"

        [target.${rustcTarget}]
        linker = "${lib.getExe moldCc}"
      '';
    };

    systemd.user = {
      services.rust-storage-gc = {
        Unit = {
          Description = "Clean Cargo checkouts and deduplicate Btrfs project extents";
        };
        Service = {
          Type = "oneshot";
          ExecStart = lib.getExe rustStorageGc;
          Nice = 19;
          IOSchedulingClass = "idle";
          CPUWeight = 10;
          IOWeight = 10;
        };
      };

      timers.rust-storage-gc = {
        Unit = {
          Description = "Weekly Cargo checkout cleanup and Btrfs deduplication";
        };
        Timer = {
          OnCalendar = "weekly";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
        Install = {
          WantedBy = [ "timers.target" ];
        };
      };
    };
  };
}
