{
  config,
  pkgs,
  lib,
  ...
}:

let
  # Source checkout — service is a no-op on machines that don't have it
  # (guarded via ConditionPathExists below). Update flow:
  #
  #   cd ~/projects/work/fulcrum && git pull
  #   systemctl --user restart fulcrum
  #
  projectRoot = "${config.home.homeDirectory}/projects/work/fulcrum";

  # Runtime library path for native modules (onnxruntime / sharp in
  # @huggingface/transformers). `libstdc++` is the one that actually
  # broke when we first tried to run under a bare PATH; keep the list
  # small to avoid pulling the world, but expand if something new
  # complains about a missing .so at boot.
  fulcrumLibs = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib    # libstdc++.so.6
    pkgs.zlib                # libz.so.1
    pkgs.glib                # libglib-2.0.so.0 (occasionally pulled by image libs)
  ];

  # Tools the service shell needs — bun to run, git so the process can
  # report its own rev via /api/version, coreutils/which for script
  # compatibility in case bun shells out.
  binPath = lib.makeBinPath [
    pkgs.bun
    pkgs.git
    pkgs.coreutils
    pkgs.which
  ];
in

{
  systemd.user.services.fulcrum = {
    Unit = {
      Description = "Fulcrum — executive operational intelligence (source)";
      Documentation = [ "file://${projectRoot}/CLAUDE.md" ];
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      # No-op on machines without the project checked out.
      ConditionPathExists = projectRoot;
    };

    Service = {
      Type = "exec";
      WorkingDirectory = projectRoot;
      Environment = [
        "PATH=${binPath}:/run/current-system/sw/bin"
        "LD_LIBRARY_PATH=${fulcrumLibs}"
        "NODE_OPTIONS=--max-old-space-size=4096"
        "FULCRUM_PORT=3100"
      ];
      # Bun auto-loads ${projectRoot}/.env so ANTHROPIC_API_KEY + friends
      # are read without us wiring EnvironmentFile= into the unit.
      ExecStart = "${pkgs.bun}/bin/bun run start";

      Restart = "on-failure";
      RestartSec = "5s";
      # Bun handles SIGTERM gracefully (drains SSE streams); give it room.
      KillMode = "mixed";
      TimeoutStopSec = "15s";

      # Soft resource ceilings to keep a runaway sub-agent from eating the
      # machine. Bump if you hit them in practice.
      MemoryHigh = "3G";
      MemoryMax = "5G";
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
