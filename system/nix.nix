{ config, pkgs, lib, inputs, ... }:

{

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

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
      safe = { directory = [ "/home/aragao/projects/personal/nix" ]; };
    };
  };

  # Automatic system updates every other day
  systemd.timers.auto-upgrade = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31 02:00:00";
      Persistent = true;
    };
  };

  systemd.services.auto-upgrade = {
    serviceConfig.Type = "oneshot";
    script = ''
      cd /home/aragao/projects/personal/nix
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake .#parallels-nixos --upgrade-all
    '';
  };

  # System-level auto-rebuild: generate script and run as root with journald logging
  systemd.services.nixos-auto-rebuild = {
    description = "Watch Nix config and auto-rebuild system";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.inotifyTools pkgs.libnotify pkgs.coreutils pkgs.util-linux pkgs.gnugrep pkgs.gawk pkgs.git ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      StandardOutput = "journal";
      StandardError = "journal";
    };
    script = ''
      set -euo pipefail

      CONFIG_DIR="/home/aragao/projects/personal/nix"
      FLAKE_NAME="parallels-nixos"

      log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
      }

      # Send desktop notification to logged-in user via user DBus
      send_notification() {
        local title="$1"
        local message="$2"
        local urgency="''${3:-normal}"

        user="aragao"
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
      inotifywait -m -r -e modify,create,delete,move --include='.*\.nix$' "$CONFIG_DIR" |
      while read -r _; do
        log "Change detected. Rebuilding..."
        start=$(date +%s)
        if ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake "$CONFIG_DIR#$FLAKE_NAME" 2>&1; then
          dur=$(( $(date +%s) - start ))
          log "Rebuild complete in ''${dur}s"
          send_notification "✅ NixOS Rebuild Complete" "Updated successfully in ''${dur}s" normal
        else
          dur=$(( $(date +%s) - start ))
          log "Rebuild failed after ''${dur}s"
          send_notification "❌ NixOS Rebuild Failed" "Check journalctl -u nixos-auto-rebuild" critical
        fi
        # Debounce rapid changes
        sleep 2
      done
    '';
  };
} 