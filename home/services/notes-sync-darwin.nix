{ config, pkgs, ... }:

# macOS counterpart to home/services/notes-sync.nix. Same git
# clone/merge/push body — runs every 15 minutes, signs with GPG,
# auto-resolves conflicts by concatenating both sides — driven by a
# launchd user agent instead of a systemd-user timer.
#
# Key differences from the Linux side:
#   - No ssh-add-keys / gpg-add-keys preloading. SSH keys are
#     preloaded at login by home/cli/ssh-agent-macos.nix; GPG
#     passphrases are cached in the macOS Keychain by pinentry-mac
#     after the first interactive sign.
#   - Notifications go through osascript instead of notify-send.
#   - No Wayland/Qt environment soup.
#   - StandardOut/Err paths under ~/Library/Logs/ so `tail -f
#     ~/Library/Logs/notes-sync.log` matches the launchd convention.

let
  homeDir = config.home.homeDirectory;

  # Same well-known socket path as home/cli/ssh-agent-macos.nix so the
  # sync inherits the agent loaded at login. Hardcoded here rather
  # than read from a module argument to keep this file self-contained.
  sshAuthSock = "${homeDir}/.ssh/agent.sock";

  syncScript = pkgs.writeShellScript "notes-sync-darwin" ''
    set -eu

    LOG="$HOME/Library/Logs/notes-sync.log"
    mkdir -p "$(dirname "$LOG")"

    log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

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

    NOTES_DIR="$HOME/projects/work/notes"
    REMOTE_URL="git@github-work:andrearagao/notes.git"

    # Clone-or-bootstrap. Same shape as the Linux script: if the dir
    # doesn't exist as a git repo, try cloning the remote; if that
    # fails (repo absent on GitHub), init locally + seed a README +
    # push. Existing non-git dirs get archived first so we never
    # silently overwrite user content.
    if [ ! -d "$NOTES_DIR/.git" ]; then
      log "Notes directory is not a git repository"

      if [ -d "$NOTES_DIR" ] && [ ! -d "$NOTES_DIR/.git" ]; then
        BACKUP_DIR="$HOME/projects/work/notes.backup.$(date +%Y%m%d-%H%M%S)"
        log "Backing up existing $NOTES_DIR -> $BACKUP_DIR"
        mv "$NOTES_DIR" "$BACKUP_DIR"
      fi

      mkdir -p "$(dirname "$NOTES_DIR")"

      log "Attempting to clone $REMOTE_URL"
      if ${pkgs.git}/bin/git clone "$REMOTE_URL" "$NOTES_DIR"; then
        log "Cloned existing repository"
      else
        log "Clone failed; initializing new repo"
        mkdir -p "$NOTES_DIR"
        cd "$NOTES_DIR"
        ${pkgs.git}/bin/git init

        cat > README.md <<EOF
    # Work Notes

    Auto-synced every 15 minutes via launchd
    (home/services/notes-sync-darwin.nix).

    Created: $(date '+%Y-%m-%d %H:%M:%S')
    EOF
        ${pkgs.git}/bin/git add README.md
        # Skip GPG signing on the seed commit — gpg-agent / Keychain
        # state isn't guaranteed during bootstrap.
        ${pkgs.git}/bin/git commit --no-gpg-sign -m "Initial commit: Add README"

        ${pkgs.git}/bin/git remote add origin "$REMOTE_URL"
        if ! ${pkgs.git}/bin/git push -u origin main; then
          log "Failed to push initial commit — does the repo exist on GitHub?"
          notify "⚠️ Notes Sync" "Created local repo but couldn't push" "critical"
        fi
      fi
    fi

    cd "$NOTES_DIR"

    # Self-heal a half-bootstrapped repo missing its origin remote.
    if ! ${pkgs.git}/bin/git remote get-url origin >/dev/null 2>&1; then
      log "Origin remote missing — re-attaching to $REMOTE_URL"
      ${pkgs.git}/bin/git remote add origin "$REMOTE_URL"
    fi

    # Idempotent git identity config — match the Linux side exactly so
    # commits from either machine are signed by the same key.
    ${pkgs.git}/bin/git config user.name "andrearagao"
    ${pkgs.git}/bin/git config user.email "$WORK_EMAIL"
    ${pkgs.git}/bin/git config user.signingkey "D8BAA25EFB1D5C5F"
    ${pkgs.git}/bin/git config commit.gpgsign true

    log "Fetching origin/main"
    if ! ${pkgs.git}/bin/git fetch origin main; then
      notify "❌ Notes Sync Failed" "git fetch failed. Check network." "critical"
      exit 1
    fi

    LOCAL_HEAD=$(${pkgs.git}/bin/git rev-parse HEAD 2>/dev/null || echo "")
    REMOTE_HEAD=$(${pkgs.git}/bin/git rev-parse origin/main 2>/dev/null || echo "")

    # Merge remote changes only when origin truly diverges from HEAD.
    # Skipping when we're already ahead avoids fast-forwarding into a
    # merge commit that re-orders our local edits.
    if [ -n "$REMOTE_HEAD" ] && [ -n "$LOCAL_HEAD" ] && [ "$LOCAL_HEAD" != "$REMOTE_HEAD" ] \
       && ! ${pkgs.git}/bin/git merge-base --is-ancestor "$REMOTE_HEAD" "$LOCAL_HEAD"; then
      log "Remote has new commits; merging"

      if ${pkgs.git}/bin/git merge origin/main --no-edit; then
        log "Merge succeeded"
      else
        log "Merge conflict — auto-resolving by combining both sides"
        CONFLICTED_FILES=$(${pkgs.git}/bin/git diff --name-only --diff-filter=U)

        for file in $CONFLICTED_FILES; do
          log "Resolving $file"
          TEMP_FILE=$(mktemp)
          {
            echo "# Auto-merged on $(date '+%Y-%m-%d %H:%M:%S')"
            echo "# This file contains all changes from both local and remote versions"
            echo ""
            # Combine both sides by deleting only the conflict markers,
            # keeping every content line once. The previous range+catch-all
            # sed printed each conflict-body line twice, duplicating the
            # local side.
            ${pkgs.gnused}/bin/sed '
              /^<<<<<<< /d
              /^=======$/d
              /^>>>>>>> /d
            ' "$file"
          } > "$TEMP_FILE"
          mv "$TEMP_FILE" "$file"
        done

        ${pkgs.git}/bin/git add .
        ${pkgs.git}/bin/git commit -m "Auto-merge: Combined all changes from local and remote $(date '+%Y-%m-%d %H:%M:%S')"
      fi
    fi

    # Stage and commit anything we've authored locally since the last
    # successful sync.
    ${pkgs.git}/bin/git add .
    if ! ${pkgs.git}/bin/git diff --cached --quiet; then
      log "Local changes detected; committing"
      ${pkgs.git}/bin/git commit -m "Auto-sync notes: $(date '+%Y-%m-%d %H:%M:%S')"
    fi

    LOCAL_HEAD=$(${pkgs.git}/bin/git rev-parse HEAD 2>/dev/null || echo "")
    REMOTE_HEAD=$(${pkgs.git}/bin/git rev-parse origin/main 2>/dev/null || echo "")

    if [ -z "$LOCAL_HEAD" ]; then
      log "No local commits yet; nothing to push"
    elif [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
      log "Local matches remote; nothing to push"
    else
      log "Pushing to origin/main"
      if ! ${pkgs.git}/bin/git push origin main; then
        notify "❌ Notes Sync Failed" "git push failed. Check network." "critical"
        exit 1
      fi
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
        # Force the work identity for the github-work alias; matches
        # the Linux side's GIT_SSH_COMMAND override.
        GIT_SSH_COMMAND = "ssh -o StrictHostKeyChecking=accept-new -i ${homeDir}/.ssh/id_rsa_work";
        # PATH the sync script's git/gnused invocations don't rely on,
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
