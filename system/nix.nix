{
  config,
  pkgs,
  lib,
  inputs,
  owner,
  ...
}:

{

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Use all CPU cores per build, pick parallel build count automatically.
  nix.settings.cores = 0;
  nix.settings.max-jobs = "auto";

  # Hardlink-dedup identical files in /nix/store (complements btrfs zstd).
  nix.settings.auto-optimise-store = true;
  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  nixpkgs.config.allowUnfree = true;

  # Allow root to treat the repo as safe when rebuilding from the system service
  programs.git = {
    enable = true;
    config = {
      safe = {
        directory = [ "/home/${owner.name}/projects/personal/nix" ];
      };
    };
  };

  # System-level auto-rebuild: generate script and run as root with journald logging
  systemd.services.nixos-auto-rebuild = {
    description = "Watch Nix config and auto-rebuild system";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.inotify-tools
      pkgs.libnotify
      pkgs.coreutils
      pkgs.util-linux
      pkgs.gnugrep
      pkgs.gawk
      pkgs.git
      pkgs.nixos-rebuild
      pkgs.nettools
    ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      StandardOutput = "journal";
      StandardError = "journal";
    };
    script = ''
      set -euo pipefail

      CONFIG_DIR="/home/${owner.name}/projects/personal/nix"
      FLAKE_NAME=$(hostname)

      log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
      }

      # Send desktop notification to logged-in user via user DBus
      send_notification() {
        local title="$1"
        local message="$2"
        local urgency="''${3:-normal}"

        user="${owner.name}"
        uid=$(id -u "$user")
        user_bus="unix:path=/run/user/''${uid}/bus"

        if [ -S "/run/user/''${uid}/bus" ]; then
          runuser -u "$user" -- ${pkgs.coreutils}/bin/env DBUS_SESSION_BUS_ADDRESS="$user_bus" ${pkgs.libnotify}/bin/notify-send \
            --app-name="NixOS Auto-Rebuild" \
            --urgency="$urgency" \
            "$title" "$message" || true
        fi
      }

      trap 'log "Stopping auto-rebuild"; exit 0' INT TERM

      log "Starting auto-rebuild monitor for $CONFIG_DIR"
      while true; do
        # Wait for first change (blocking)
        log "Waiting for file changes..."
        inotifywait -r -q -e modify,create,delete,move --include='.*\.nix$' "$CONFIG_DIR" >/dev/null 2>&1
        
        # Now batch any additional changes with 2-second timeout
        log "Change detected, waiting for quiet period..."
        while timeout 2 inotifywait -r -q -e modify,create,delete,move --include='.*\.nix$' "$CONFIG_DIR" >/dev/null 2>&1; do
          : # Keep resetting timeout while more changes come
        done
        
        # 2s quiet period reached, rebuild now
        log "Rebuilding after 2s quiet period..."
        start=$(date +%s)
        if nixos-rebuild switch --flake "$CONFIG_DIR#$FLAKE_NAME" 2>&1; then
          dur=$(( $(date +%s) - start ))
          log "Rebuild complete in ''${dur}s"
          send_notification "✅ NixOS Rebuild Complete" "Updated successfully in ''${dur}s" normal
        else
          dur=$(( $(date +%s) - start ))
          log "Rebuild failed after ''${dur}s"
          send_notification "❌ NixOS Rebuild Failed" "Check journalctl -u nixos-auto-rebuild" critical
        fi
      done
    '';
  };
}
