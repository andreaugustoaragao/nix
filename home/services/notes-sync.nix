{ config, pkgs, lib, ... }:

{
  # Systemd service to sync notes directory with GitHub
  systemd.user.services.notes-sync = {
    Unit = {
      Description = "Sync notes directory with GitHub";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    
    Service = {
      Type = "oneshot";
      WorkingDirectory = "%h/projects/work/notes";
      Environment = [
        "SSH_AUTH_SOCK=%t/gnupg/S.gpg-agent.ssh"
        "GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=accept-new"
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
        
        # Ensure notes directory exists
        mkdir -p "$NOTES_DIR"
        cd "$NOTES_DIR"
        
        # Initialize git repo if it doesn't exist
        if [[ ! -d .git ]]; then
          echo "Initializing git repository..."
          ${pkgs.git}/bin/git init
          ${pkgs.git}/bin/git config user.name "Notes Sync Service"
          ${pkgs.git}/bin/git config user.email "aragao@avaya.com"
          
          # Add a README if the repo is empty
          if [[ ! -f README.md ]]; then
            cat > README.md <<EOF
        # Work Notes

        This repository contains my work notes, automatically synced via systemd service.

        ## Structure
        - Notes are stored as Markdown files (.md)
        - Subdirectories are supported for organization
        - Auto-synced every 30 minutes

        Created: $(date '+%Y-%m-%d %H:%M:%S')
        EOF
          fi
        fi
        
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