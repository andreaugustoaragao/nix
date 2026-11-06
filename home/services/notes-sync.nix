{ config, pkgs, ... }:

let
  reconcile = pkgs.writeShellScript "notes-sync-reconcile" (
    builtins.readFile ./notes-sync-reconcile.sh
  );
in
{
  # Systemd service to sync notes directory with GitHub
  systemd.user.services.notes-sync = {
    Unit = {
      Description = "Sync notes directory with GitHub";
      After = [
        "network-online.target"
        "ssh-agent.service"
      ];
      Wants = [
        "network-online.target"
        "ssh-agent.service"
      ];
    };

    Service = {
      Type = "oneshot";
      WorkingDirectory = "%h/projects/work/notes";
      Environment = [
        "SSH_AUTH_SOCK=%t/ssh-agent"
        "SSH_ASKPASS=${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass"
        "DISPLAY=:0"
        "QT_QPA_PLATFORM=wayland"
        "GPG_TTY=/dev/null"
        "PINENTRY_USER_DATA=qt"
        "GIT_SSH_COMMAND=\"ssh -o StrictHostKeyChecking=accept-new -i %h/.ssh/id_rsa_work\""
        "PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin"
        "NOTES_SYNC_GIT=${pkgs.git}/bin/git"
      ];

      ExecStart = pkgs.writeShellScript "notes-sync" ''
        set -eu

        # Refuse unfinished Git work before credentials or repository changes.
        ${reconcile} --check

        WORK_EMAIL_FILE="/run/secrets/git_email_work"
        if [ ! -f "$WORK_EMAIL_FILE" ]; then
          echo "Work email secret missing; skipping notes sync"
          exit 0
        fi
        WORK_EMAIL="$(cat "$WORK_EMAIL_FILE")"
        if [ -z "$WORK_EMAIL" ] || [ "$WORK_EMAIL" = "placeholder" ]; then
          echo "Work email secret unavailable; skipping notes sync"
          exit 0
        fi

        ssh-add-keys
        gpg-add-keys
        ${pkgs.git}/bin/git config user.name "andrearagao"
        ${pkgs.git}/bin/git config user.email "$WORK_EMAIL"
        ${pkgs.git}/bin/git config user.signingkey "D8BAA25EFB1D5C5F"
        ${pkgs.git}/bin/git config commit.gpgsign true

        if ! ${reconcile}; then
          ${pkgs.libnotify}/bin/notify-send --urgency=critical --app-name="Notes Sync" \
            "Notes Sync Failed" "Notes were preserved. Check journalctl --user -u notes-sync."
          exit 1
        fi
      '';

      # No Restart=. The 15-minute timer below IS the retry mechanism, and
      # layering Restart=on-failure/RestartSec=30s on top of it meant a
      # *persistent* failure (e.g. the remote being unreachable) retried
      # every 30s forever — 166 restarts and ~42 critical desktop
      # notifications an hour during one such outage. A start-limit cap
      # isn't the fix either: once systemd trips a start limit it refuses
      # further starts, which would block the timer too. Letting the unit
      # fail and wait for the next timer tick backs off correctly and keeps
      # the failure notification to once per quarter hour.
    };
  };

  # Systemd timer to run sync every 15 minutes
  systemd.user.timers.notes-sync = {
    Unit = {
      Description = "Run notes sync every 15 minutes";
      Requires = [ "notes-sync.service" ];
    };

    Timer = {
      OnCalendar = "*:0/15"; # Every 15 minutes
      Persistent = true; # Run immediately if missed
      RandomizedDelaySec = "2m"; # Add some randomization
    };

    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
