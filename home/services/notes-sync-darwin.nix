{ config, pkgs, ... }:

# macOS uses the same conflict-preserving reconciliation as Linux.
# SSH keys load at login; signing uses the existing Keychain-backed GPG agent.

let
  homeDir = config.home.homeDirectory;
  reconcile = pkgs.writeShellScript "notes-sync-reconcile" (
    builtins.readFile ./notes-sync-reconcile.sh
  );

  # Same well-known socket path as home/cli/ssh-agent-macos.nix so the
  # sync inherits the agent loaded at login. Hardcoded here rather
  # than read from a module argument to keep this file self-contained.
  sshAuthSock = "${homeDir}/.ssh/agent.sock";

  syncScript = pkgs.writeShellScript "notes-sync-darwin" ''
    set -eu

    LOG="$HOME/Library/Logs/notes-sync.log"
    mkdir -p "$(dirname "$LOG")"

    log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

    cd "$HOME/projects/work/notes"
    ${reconcile} --check

    # Work email lives in sops to keep the employer DNS out of the
    # Nix store. If sops hasn't deployed it on this host yet, exit
    # cleanly — the launchd agent re-fires every 15 minutes, so
    # operations resume automatically once /run/secrets is populated.
    WORK_EMAIL_FILE="/run/secrets/git_email_work"
    if [ ! -f "$WORK_EMAIL_FILE" ]; then
      log "Work email secret missing at $WORK_EMAIL_FILE; skipping this run"
      exit 0
    fi
    WORK_EMAIL="$(cat "$WORK_EMAIL_FILE")"
    if [ -z "$WORK_EMAIL" ] || [ "$WORK_EMAIL" = "placeholder" ]; then
      log "Work email secret empty/placeholder; skipping this run"
      exit 0
    fi

    # Only critical messages surface as macOS notifications, matching
    # the Linux side's notify() policy (avoid notification fatigue).
    # Lower-priority "syncing"/"complete" messages are still logged.
    notify() {
      local title="$1" message="$2" urgency="''${3:-normal}"
      if [ "$urgency" = "critical" ]; then
        /usr/bin/osascript \
          -e "on run argv
                display notification (item 1 of argv) with title (item 2 of argv)
              end run" \
          "$message" "$title" >/dev/null 2>&1 || true
      fi
    }

    handle_error() {
      notify "❌ Notes Sync Failed" "Unexpected error. See $LOG" "critical"
      exit 1
    }
    trap handle_error ERR

    # Idempotent git identity config — match the Linux side exactly so
    # commits from either machine are signed by the same key.
    ${pkgs.git}/bin/git config user.name "andrearagao"
    ${pkgs.git}/bin/git config user.email "$WORK_EMAIL"
    ${pkgs.git}/bin/git config user.signingkey "D8BAA25EFB1D5C5F"
    ${pkgs.git}/bin/git config commit.gpgsign true

    if ! ${reconcile}; then
      notify "Notes Sync Failed" "Notes were preserved. See $LOG" "critical"
      exit 1
    fi

    log "Sync complete"
  '';
in
{
  launchd.agents.notes-sync = {
    enable = true;
    config = {
      Label = "org.nix-home.notes-sync";
      ProgramArguments = [ "${syncScript}" ];

      # Every 15 minutes, matching the Linux systemd timer cadence.
      # StartInterval is wall-clock-relative; macOS coalesces nearby
      # fire times across launchd jobs, so the exact tick may drift
      # by a few seconds.
      StartInterval = 900;

      # Fire once at login so a freshly-booted machine picks up other
      # machines' commits without waiting up to 15 minutes for the
      # first interval. The Linux side gets this via the timer's
      # `Persistent = true` (catch-up on missed firings).
      RunAtLoad = true;

      EnvironmentVariables = {
        # Talk to the agent loaded by ssh-agent-macos.nix at login.
        SSH_AUTH_SOCK = sshAuthSock;
        NOTES_SYNC_GIT = "${pkgs.git}/bin/git";
        # Force the work identity for the github-work alias; matches
        # the Linux side's GIT_SSH_COMMAND override.
        GIT_SSH_COMMAND = "ssh -o StrictHostKeyChecking=accept-new -i ${homeDir}/.ssh/id_rsa_work";
        # Managed Git uses absolute paths; its external helpers use PATH,
        # but git itself shells out to a few helpers (askpass, etc.)
        # that resolve through this. Match darwin-auto-upgrade.nix.
        PATH = "/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };

      # Logs collocate with the auto-upgrade and ssh-agent logs so the
      # whole launchd-managed user surface is greppable in one place.
      StandardOutPath = "${homeDir}/Library/Logs/notes-sync.log";
      StandardErrorPath = "${homeDir}/Library/Logs/notes-sync.log";
    };
  };
}
