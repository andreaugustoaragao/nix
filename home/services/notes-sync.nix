{ config, pkgs, ... }:

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
      ];

      # Script to sync notes with git
      ExecStart = pkgs.writeShellScript "notes-sync" ''
                set -eu

                # Work email lives in sops to keep the employer DNS out of
                # the Nix store. If sops hasn't deployed it on this host yet,
                # exit cleanly — the systemd timer re-fires every 15 minutes,
                # so syncing resumes automatically once /run/secrets is
                # populated. This must come BEFORE ssh/gpg key loading so we
                # don't waste agent slots on a no-op run.
                WORK_EMAIL_FILE="/run/secrets/git_email_work"
                if [ ! -f "$WORK_EMAIL_FILE" ]; then
                  echo "Work email secret missing at $WORK_EMAIL_FILE; skipping this run"
                  exit 0
                fi
                WORK_EMAIL="$(cat "$WORK_EMAIL_FILE")"
                if [ -z "$WORK_EMAIL" ] || [ "$WORK_EMAIL" = "placeholder" ]; then
                  echo "Work email secret empty/placeholder; skipping this run"
                  exit 0
                fi

                # Load SSH keys — fatal on failure. Without these we cannot reach
                # GitHub, and proceeding would corrupt local state (the clone
                # would fail and the init fallback would create a remote-less
                # repo that the script then accretes commits into forever).
                echo "Loading SSH keys..."
                if ! command -v ssh-add-keys >/dev/null 2>&1; then
                  echo "Fatal: ssh-add-keys not found in PATH" >&2
                  exit 1
                fi
                ssh-add-keys

                # Preload GPG keys — fatal on failure. Without these, signed
                # commits fail mid-sync and leave the repo half-updated.
                echo "Preloading GPG keys..."
                if ! command -v gpg-add-keys >/dev/null 2>&1; then
                  echo "Fatal: gpg-add-keys not found in PATH" >&2
                  exit 1
                fi
                gpg-add-keys
                
                # Function to send desktop notification — only fires on failures.
                # All call sites still pass success/info messages, but those are
                # silently dropped here. Tail journalctl --user -u notes-sync for
                # the full picture.
                notify() {
                  local title="$1"
                  local message="$2"
                  local urgency="''${3:-normal}"
                  if [ "$urgency" = "critical" ]; then
                    ${pkgs.libnotify}/bin/notify-send --urgency="$urgency" --app-name="Notes Sync" "$title" "$message"
                  fi
                }
                
                # Error handler for unexpected failures
                handle_error() {
                  notify "❌ Notes Sync Failed" "Unexpected error occurred during sync. Check logs with: journalctl --user -u notes-sync" "critical"
                  exit 1
                }
                
                # Set up error trap
                trap handle_error ERR
                
                NOTES_DIR="$HOME/projects/work/notes"
                REMOTE_URL="git@github-work:andrearagao/notes.git"
                
                # Clone or configure the repository
                if [[ ! -d "$NOTES_DIR/.git" ]]; then
                  echo "Notes directory doesn't exist or is not a git repository"
                  
                  # If directory exists but is not a git repo, back it up
                  if [[ -d "$NOTES_DIR" ]] && [[ ! -d "$NOTES_DIR/.git" ]]; then
                    echo "Backing up existing notes directory..."
                    BACKUP_DIR="$HOME/projects/work/notes.backup.$(date +%Y%m%d-%H%M%S)"
                    mv "$NOTES_DIR" "$BACKUP_DIR"
                    notify "📝 Notes Sync" "Backed up existing notes to: $BACKUP_DIR"
                  fi
                  
                  # Ensure parent directory exists
                  mkdir -p "$(dirname "$NOTES_DIR")"
                  
                  echo "Attempting to clone existing repository..."
                  if ${pkgs.git}/bin/git clone "$REMOTE_URL" "$NOTES_DIR"; then
                    echo "Successfully cloned existing repository"
                    notify "📝 Notes Sync" "Cloned existing notes repository from GitHub"
                  else
                    echo "Clone failed (repository might not exist), creating new repository..."
                    mkdir -p "$NOTES_DIR"
                    cd "$NOTES_DIR"
                    ${pkgs.git}/bin/git init
                    
                    # Add a README for new repository
                    cat > README.md <<EOF
        # Work Notes

        This repository contains my work notes, automatically synced via systemd service.

        ## Structure
        - Notes are stored as Markdown files (.md)
        - Subdirectories are supported for organization
        - Auto-synced every 15 minutes

        Created: $(date '+%Y-%m-%d %H:%M:%S')
        EOF
                    ${pkgs.git}/bin/git add README.md
                    # Skip GPG signing on the seed commit — it runs before the
                    # repo-local commit.gpgsign config is set, and we don't want
                    # the bootstrap to depend on GPG agent state.
                    ${pkgs.git}/bin/git commit --no-gpg-sign -m "Initial commit: Add README"
                    
                    # Set up remote and push
                    ${pkgs.git}/bin/git remote add origin "$REMOTE_URL"
                    echo "Pushing initial commit to remote..."
                    if ! ${pkgs.git}/bin/git push -u origin main; then
                      echo "Failed to push initial commit - repository might not exist on GitHub"
                      notify "⚠️ Notes Sync Warning" "Created local repository but couldn't push to GitHub. Please create the repository on GitHub." "normal"
                    else
                      notify "📝 Notes Sync" "Created and pushed new notes repository to GitHub"
                    fi
                  fi
                fi
                
                # Ensure we're in the correct directory
                cd "$NOTES_DIR"

                # Heal a half-bootstrapped repo: if .git exists but origin is
                # missing (e.g., a prior run died between `git init` and
                # `git remote add origin`), re-attach the remote here so every
                # subsequent run is idempotent.
                if ! ${pkgs.git}/bin/git remote get-url origin >/dev/null 2>&1; then
                  echo "Origin remote missing — re-attaching to $REMOTE_URL"
                  ${pkgs.git}/bin/git remote add origin "$REMOTE_URL"
                fi

                # Configure git settings (in case they're not set)
                ${pkgs.git}/bin/git config user.name "andrearagao"
                ${pkgs.git}/bin/git config user.email "$WORK_EMAIL"
                ${pkgs.git}/bin/git config user.signingkey "D8BAA25EFB1D5C5F"
                ${pkgs.git}/bin/git config commit.gpgsign true

                # Fetch remote changes FIRST, unconditionally — pulling other
                # machines' work must not depend on this machine having local
                # changes to commit.
                echo "Fetching remote changes..."
                if ! ${pkgs.git}/bin/git fetch origin main; then
                  echo "Fetch failed"
                  notify "❌ Notes Sync Failed" "Failed to fetch from remote. Check network connection." "critical"
                  exit 1
                fi

                # Merge remote into local if remote has commits we don't have.
                LOCAL_HEAD=$(${pkgs.git}/bin/git rev-parse HEAD 2>/dev/null || echo "")
                REMOTE_HEAD=$(${pkgs.git}/bin/git rev-parse origin/main 2>/dev/null || echo "")

                if [[ -n "$REMOTE_HEAD" && -n "$LOCAL_HEAD" && "$LOCAL_HEAD" != "$REMOTE_HEAD" ]] \
                   && ! ${pkgs.git}/bin/git merge-base --is-ancestor "$REMOTE_HEAD" "$LOCAL_HEAD"; then
                  echo "Remote has changes. Attempting to merge..."

                  if ${pkgs.git}/bin/git merge origin/main --no-edit; then
                    echo "Successfully merged remote changes"
                    notify "🔄 Notes Sync" "Merged remote changes with your local notes"
                  else
                    echo "Merge conflict detected. Auto-resolving by combining all changes..."

                    CONFLICTED_FILES=$(${pkgs.git}/bin/git diff --name-only --diff-filter=U)

                    for file in $CONFLICTED_FILES; do
                      echo "Auto-resolving conflicts in: $file"
                      TEMP_FILE=$(mktemp)
                      {
                        echo "# Auto-merged on $(date '+%Y-%m-%d %H:%M:%S')"
                        echo "# This file contains all changes from both local and remote versions"
                        echo ""
                        ${pkgs.gnused}/bin/sed -n '
                          /^<<<<<<< HEAD$/,/^=======$/{
                            /^<<<<<<< HEAD$/d
                            /^=======$/d
                            p
                          }
                          /^=======$/,/^>>>>>>> /{
                            /^=======$/d
                            /^>>>>>>> /d
                            p
                          }
                          /^[^<>=]/p
                        ' "$file"
                      } > "$TEMP_FILE"
                      mv "$TEMP_FILE" "$file"
                      echo "Resolved $file by combining all changes"
                    done

                    ${pkgs.git}/bin/git add .
                    ${pkgs.git}/bin/git commit -m "Auto-merge: Combined all changes from local and remote $(date '+%Y-%m-%d %H:%M:%S')"
                    notify "🔄 Notes Sync" "Auto-resolved conflicts by combining all changes from both devices"
                  fi
                fi

                # Stage and commit any local changes.
                ${pkgs.git}/bin/git add .
                if ! ${pkgs.git}/bin/git diff --cached --quiet; then
                  notify "📝 Notes Sync" "Syncing notes changes with remote repository..."
                  COMMIT_MSG="Auto-sync notes: $(date '+%Y-%m-%d %H:%M:%S')"
                  ${pkgs.git}/bin/git commit -m "$COMMIT_MSG"
                fi

                # Push if local is ahead of remote.
                LOCAL_HEAD=$(${pkgs.git}/bin/git rev-parse HEAD 2>/dev/null || echo "")
                REMOTE_HEAD=$(${pkgs.git}/bin/git rev-parse origin/main 2>/dev/null || echo "")

                if [[ -z "$LOCAL_HEAD" ]]; then
                  echo "No local commits yet; nothing to push"
                elif [[ "$LOCAL_HEAD" == "$REMOTE_HEAD" ]]; then
                  echo "Local matches remote; nothing to push"
                else
                  echo "Pushing to remote..."
                  if ! ${pkgs.git}/bin/git push origin main; then
                    echo "Push failed"
                    notify "❌ Notes Sync Failed" "Failed to push to remote repository. Check network connection." "critical"
                    exit 1
                  fi
                  notify "✅ Notes Sync Complete" "Successfully synced changes to GitHub" "low"
                fi

                echo "Notes sync completed successfully"
      '';

      # Restart policy
      Restart = "on-failure";
      RestartSec = "30s";
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
