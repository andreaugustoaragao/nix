{ config, pkgs, lib, ... }:

{
  # Systemd service to sync notes directory with GitHub
  systemd.user.services.notes-sync = {
    Unit = {
      Description = "Sync notes directory with GitHub";
      After = [ "network-online.target" "ssh-agent.service" "ssh-add-keys.service" ];
      Wants = [ "network-online.target" "ssh-agent.service" ];
      Requires = [ "ssh-add-keys.service" ];
    };
    
    Service = {
      Type = "oneshot";
      WorkingDirectory = "%h/projects/work/notes";
      Environment = [
        "SSH_AUTH_SOCK=%t/ssh-agent"
        "SSH_ASKPASS=${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass"
        "DISPLAY=:0"
        "GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=accept-new -i %h/.ssh/id_rsa_work"
      ];
      
      # Script to sync notes with git
      ExecStart = pkgs.writeShellScript "notes-sync" ''
        set -eu
        
        # Function to send desktop notification
        notify() {
          local title="$1"
          local message="$2"
          local urgency="''${3:-normal}"
          ${pkgs.libnotify}/bin/notify-send --urgency="$urgency" --app-name="Notes Sync" "$title" "$message"
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
            ${pkgs.git}/bin/git commit -m "Initial commit: Add README"
            
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
        
        # Configure git settings (in case they're not set)
        ${pkgs.git}/bin/git config user.name "andrearagao"
        ${pkgs.git}/bin/git config user.email "aragao@avaya.com"
        ${pkgs.git}/bin/git config user.signingkey "D8BAA25EFB1D5C5F"
        ${pkgs.git}/bin/git config commit.gpgsign true
        
        # Add all changes
        ${pkgs.git}/bin/git add .
        
        # Check if there are any changes to commit
        if ${pkgs.git}/bin/git diff --cached --quiet; then
          echo "No changes to sync"
          exit 0
        fi
        
        # Only notify when there are actual changes to sync
        notify "📝 Notes Sync" "Syncing notes changes with remote repository..."
        
        # Commit changes with timestamp
        COMMIT_MSG="Auto-sync notes: $(date '+%Y-%m-%d %H:%M:%S')"
        ${pkgs.git}/bin/git commit -m "$COMMIT_MSG"
        
        # Fetch remote changes first (if remote exists)
        if ${pkgs.git}/bin/git remote | grep -q origin; then
          echo "Fetching remote changes..."
          if ! ${pkgs.git}/bin/git fetch origin main; then
            echo "Fetch failed - continuing without remote sync"
            notify "⚠️ Notes Sync Warning" "Failed to fetch from remote. Continuing with local changes only." "low"
          else
            # Check if remote has commits we don't have
            LOCAL_HEAD=$(${pkgs.git}/bin/git rev-parse HEAD)
            REMOTE_HEAD=$(${pkgs.git}/bin/git rev-parse origin/main 2>/dev/null || echo "")
            
            if [[ -n "$REMOTE_HEAD" && "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
              echo "Remote has changes. Attempting to merge..."
              
              # Try to merge, but handle conflicts gracefully
              if ${pkgs.git}/bin/git merge origin/main --no-edit; then
                echo "Successfully merged remote changes"
                notify "🔄 Notes Sync" "Merged remote changes with your local notes"
              else
                echo "Merge conflict detected. Auto-resolving by combining all changes..."
                
                # Find all conflicted files
                CONFLICTED_FILES=$(${pkgs.git}/bin/git diff --name-only --diff-filter=U)
                
                for file in $CONFLICTED_FILES; do
                  echo "Auto-resolving conflicts in: $file"
                  
                  # Create a temp file to store the merged content
                  TEMP_FILE=$(mktemp)
                  
                  # Extract all unique lines from both versions
                  # This combines local and remote changes by keeping all lines
                  {
                    echo "# Auto-merged on $(date '+%Y-%m-%d %H:%M:%S')"
                    echo "# This file contains all changes from both local and remote versions"
                    echo ""
                    
                    # Get the content without conflict markers, combining both sides
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
                  
                  # Replace the conflicted file with the merged version
                  mv "$TEMP_FILE" "$file"
                  
                  echo "Resolved $file by combining all changes"
                done
                
                # Stage all resolved files
                ${pkgs.git}/bin/git add .
                
                # Commit the auto-resolution
                ${pkgs.git}/bin/git commit -m "Auto-merge: Combined all changes from local and remote $(date '+%Y-%m-%d %H:%M:%S')"
                
                echo "Successfully auto-resolved conflicts by combining all changes"
                notify "🔄 Notes Sync" "Auto-resolved conflicts by combining all changes from both devices"
              fi
            fi
          fi
        else
          echo "No remote configured yet. Add with: git remote add origin <repo-url>"
        fi
        
        # Push to remote (if configured)
        if ${pkgs.git}/bin/git remote | grep -q origin; then
          echo "Pushing to remote..."
          if ! ${pkgs.git}/bin/git push origin main; then
            echo "Push failed - possibly due to conflicts or network issues"
            echo "Check git status manually: cd ~/projects/work/notes && git status"
            notify "❌ Notes Sync Failed" "Failed to push to remote repository. Check network connection." "critical"
            exit 1
          else
            notify "✅ Notes Sync Complete" "Successfully synced changes to GitHub" "low"
          fi
        else
          # Local commit successful but no remote
          notify "✅ Notes Sync Complete" "Changes committed locally (no remote configured)" "low"
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
      OnCalendar = "*:0/15";  # Every 15 minutes
      Persistent = true;      # Run immediately if missed
      RandomizedDelaySec = "2m";  # Add some randomization
    };
    
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}