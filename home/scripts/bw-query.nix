{ config, pkgs, lib, ... }:

{
  home.packages = [
    (pkgs.writeShellScriptBin "bw-query" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # Colors for output
      RED='\033[0;31m'
      GREEN='\033[0;32m'
      YELLOW='\033[1;33m'
      NC='\033[0m' # No Color

      log() {
        echo -e "''${GREEN}[bw-query $(date '+%H:%M:%S')]''${NC} $1" >&2
      }

      error() {
        echo -e "''${RED}[bw-query ERROR $(date '+%H:%M:%S')]''${NC} $1" >&2
        exit 1
      }

      warn() {
        echo -e "''${YELLOW}[bw-query WARN $(date '+%H:%M:%S')]''${NC} $1" >&2
      }

      # Check if secrets are available
      if [[ ! -f /run/secrets/bitwarden/email ]]; then
        error "Bitwarden secrets not available. Make sure sops is configured and system is rebuilt."
      fi

      # Read secrets from sops
      BW_EMAIL=$(cat /run/secrets/bitwarden/email)
      BW_SERVER=$(cat /run/secrets/bitwarden/server_url)
      BW_PASSWORD=$(cat /run/secrets/bitwarden/master_password)

      log "Setting up Bitwarden CLI..."

      # Try to load existing session first and test it quickly
      BW_SESSION=""
      SKIP_FULL_SETUP=false
      
      if [[ -f ~/.cache/bw_session ]]; then
        CACHED_SESSION=$(cat ~/.cache/bw_session 2>/dev/null || echo "")
        if [[ -n "$CACHED_SESSION" ]]; then
          export BW_SESSION="$CACHED_SESSION"
          log "Using cached session (trusting cache)"
          SKIP_FULL_SETUP=true
        fi
      fi

      # Skip all the slow setup if we have a working cached session
      if [[ "$SKIP_FULL_SETUP" == "false" ]]; then
        # Check login status
        BW_STATUS=$(bw status | ${pkgs.jq}/bin/jq -r .status)
        CURRENT_SERVER=$(bw config server 2>/dev/null || echo "")
        
        # Only mess with server config if we're not logged in or server is wrong
        if [[ "$BW_STATUS" == "unauthenticated" ]]; then
          if [[ "$CURRENT_SERVER" != "$BW_SERVER" ]]; then
            log "Configuring server: $BW_SERVER"
            if ! bw config server "$BW_SERVER" >/dev/null 2>&1; then
              error "Failed to configure Bitwarden server: $BW_SERVER"
            fi
          else
            log "Server already configured: $BW_SERVER"
          fi
        elif [[ "$CURRENT_SERVER" != "$BW_SERVER" ]]; then
          log "Server mismatch detected (logged in to different server), logging out..."
          bw logout >/dev/null 2>&1
          BW_STATUS="unauthenticated"
          log "Configuring server: $BW_SERVER"
          if ! bw config server "$BW_SERVER" >/dev/null 2>&1; then
            error "Failed to configure Bitwarden server: $BW_SERVER"
          fi
        else
          log "Already logged in to correct server"
        fi
        case "$BW_STATUS" in
          "unauthenticated")
            log "Logging in to Bitwarden..."
            # Use a more robust login method
            if ! BW_SESSION=$(printf '%s' "$BW_PASSWORD" | bw login "$BW_EMAIL" --raw 2>/dev/null); then
              error "Failed to login to Bitwarden. Check your credentials."
            fi
            log "Login successful"
            ;;
          "locked")
            log "Vault is locked, unlocking..."
            if ! BW_SESSION=$(printf '%s' "$BW_PASSWORD" | bw unlock --raw 2>/dev/null); then
              error "Failed to unlock vault. Check your master password."
            fi
            ;;
          "unlocked")
            log "Already unlocked, getting session..."
            # Get current session or unlock again
            if ! BW_SESSION=$(printf '%s' "$BW_PASSWORD" | bw unlock --raw 2>/dev/null); then
              error "Failed to get session token"
            fi
            ;;
        esac

        # Verify we have a session
        if [[ -z "$BW_SESSION" ]]; then
          error "No session token obtained"
        fi

        export BW_SESSION
        
        # Save session for future runs
        echo "$BW_SESSION" > ~/.cache/bw_session 2>/dev/null || true
      fi

      # Only sync if data is stale (more than 1 hour old) or forced
      # Skip sync check entirely if using cached session to save time
      if [[ "$SKIP_FULL_SETUP" == "false" ]]; then
        LAST_SYNC=$(bw status | ${pkgs.jq}/bin/jq -r '.lastSync // empty' 2>/dev/null)
        if [[ -n "$LAST_SYNC" ]]; then
          LAST_SYNC_EPOCH=$(date -d "$LAST_SYNC" +%s 2>/dev/null || echo 0)
          CURRENT_EPOCH=$(date +%s)
          AGE_HOURS=$(( (CURRENT_EPOCH - LAST_SYNC_EPOCH) / 3600 ))
          
          if [[ $AGE_HOURS -gt 1 ]]; then
            log "Data is $AGE_HOURS hours old, syncing..."
            bw sync >/dev/null 2>&1 || warn "Sync failed, continuing with cached data..."
          else
            log "Using cached data (synced $AGE_HOURS hours ago)"
          fi
        else
          log "No previous sync found, syncing..."
          bw sync >/dev/null 2>&1 || warn "Sync failed, continuing..."
        fi
      else
        log "Skipping sync check (using cached session)"
      fi

      # Handle special flags first
      FORCE_SYNC=false
      if [[ $# -gt 0 && "$1" == "--sync" ]]; then
        FORCE_SYNC=true
        shift  # Remove --sync from arguments
        log "Force sync requested..."
        bw sync >/dev/null 2>&1 || warn "Sync failed, continuing with cached data..."
      fi

      # Handle query
      if [[ $# -eq 0 ]]; then
        log "Opening interactive password selector..."
        
        # Get all items and format for fzf
        if ! items=$(bw list items 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[] | "\(.name)|\(.login.username // "")"' 2>/dev/null); then
          log "Cached session expired, clearing cache and re-authenticating..."
          rm -f ~/.cache/bw_session
          exec "$0" "$@"  # Re-run the script with same arguments, will go through full setup
        fi
        
        if [[ -z "$items" ]]; then
          error "No items found in vault"
        fi
        
        # Use fzf to select item with detailed preview
        selected=$(echo "$items" | BW_SESSION="$BW_SESSION" ${pkgs.fzf}/bin/fzf \
          --delimiter='|' \
          --with-nth=1,2 \
          --preview='
            item_name="{1}"
            echo "📝 Name: $item_name"
            echo "👤 Username: {2}"
            echo ""
            echo "Loading details..."
            bw get item "$item_name" 2>/dev/null | ${pkgs.jq}/bin/jq -r "
              \"🌐 URL: \" + ((.login.uris[0].uri // \"N/A\")) + \"\n\" +
              \"📂 Folder: \" + (.folderName // \"No Folder\") + \"\n\" +
              \"🏷️  Type: \" + (if .type == 1 then \"Login\" elif .type == 2 then \"Secure Note\" elif .type == 3 then \"Card\" elif .type == 4 then \"Identity\" else \"Unknown\" end) + \"\n\" +
              (if .notes and (.notes != \"\") then \"📋 Notes: \" + .notes + \"\n\" else \"\" end) +
              (if (.login.totp // null) then \"🔐 TOTP: Available\" else \"\" end)
            " 2>/dev/null || echo "Details unavailable"
          ' \
          --preview-window=right:50% \
          --prompt="Select password entry: " \
          --height=60% \
          --border)
        
        if [[ -n "$selected" ]]; then
          # Extract just the name (before the |)
          item_name=$(echo "$selected" | cut -d'|' -f1)
          log "Getting password for: $item_name"
          
          # Get password and copy to clipboard
          if password=$(bw get password "$item_name" 2>/dev/null); then
            echo -n "$password" | ${pkgs.wl-clipboard}/bin/wl-copy
            log "Password copied to clipboard!"
          else
            error "Failed to get password for '$item_name'"
          fi
        else
          log "No item selected"
        fi
        exit 0
      fi

      case "$1" in
        --list)
          log "Listing all items..."
          bw list items | ${pkgs.jq}/bin/jq -r '.[] | "\(.name) (\(.login.username // "no username"))"' | sort
          ;;
        --password)
          if [[ $# -lt 2 ]]; then
            error "Usage: bw-query --password <item-name>"
          fi
          if ! password=$(bw get password "$2" 2>/dev/null); then
            log "Cached session expired, clearing cache and re-authenticating..."
            rm -f ~/.cache/bw_session
            exec "$0" "$@"  # Re-run the script with same arguments
          fi
          echo -n "$password" | ${pkgs.wl-clipboard}/bin/wl-copy
          log "Password copied to clipboard!"
          ;;
        --username)
          if [[ $# -lt 2 ]]; then
            error "Usage: bw-query --username <item-name>"
          fi
          if ! username=$(bw get username "$2" 2>/dev/null); then
            log "Cached session expired, clearing cache and re-authenticating..."
            rm -f ~/.cache/bw_session
            exec "$0" "$@"  # Re-run the script with same arguments
          fi
          echo -n "$username" | ${pkgs.wl-clipboard}/bin/wl-copy
          log "Username copied to clipboard!"
          ;;
        --search)
          if [[ $# -lt 2 ]]; then
            error "Usage: bw-query --search <term>"
          fi
          # Search and use fzf for selection
          if ! items=$(bw list items --search "$2" 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[] | "\(.name)|\(.login.username // "")"' 2>/dev/null); then
            log "Cached session expired, clearing cache and re-authenticating..."
            rm -f ~/.cache/bw_session
            exec "$0" "$@"  # Re-run the script with same arguments
          fi
          
          if [[ -z "$items" ]]; then
            error "No items found matching: $2"
          fi
          
          selected=$(echo "$items" | BW_SESSION="$BW_SESSION" ${pkgs.fzf}/bin/fzf \
            --delimiter='|' \
            --with-nth=1,2 \
            --preview='
              item_name="{1}"
              echo "📝 Name: $item_name"
              echo "👤 Username: {2}"
              echo ""
              echo "Loading details..."
              bw get item "$item_name" 2>/dev/null | ${pkgs.jq}/bin/jq -r "
                \"🌐 URL: \" + ((.login.uris[0].uri // \"N/A\")) + \"\n\" +
                \"📂 Folder: \" + (.folderName // \"No Folder\") + \"\n\" +
                \"🏷️  Type: \" + (if .type == 1 then \"Login\" elif .type == 2 then \"Secure Note\" elif .type == 3 then \"Card\" elif .type == 4 then \"Identity\" else \"Unknown\" end) + \"\n\" +
                (if .notes and (.notes != \"\") then \"📋 Notes: \" + .notes + \"\n\" else \"\" end) +
                (if (.login.totp // null) then \"🔐 TOTP: Available\" else \"\" end)
              " 2>/dev/null || echo "Details unavailable"
            ' \
            --preview-window=right:50% \
            --prompt="Select from search results: " \
            --height=60% \
            --border)
          
          if [[ -n "$selected" ]]; then
            item_name=$(echo "$selected" | cut -d'|' -f1)
            log "Getting password for: $item_name"
            
            if password=$(bw get password "$item_name" 2>/dev/null); then
              echo -n "$password" | ${pkgs.wl-clipboard}/bin/wl-copy
              log "Password copied to clipboard!"
            else
              error "Failed to get password for '$item_name'"
            fi
          else
            log "No item selected"
          fi
          ;;
        *)
          # Default behavior: search and use fzf for selection
          log "Searching for: $1"
          if ! items=$(bw list items --search "$1" 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[] | "\(.name)|\(.login.username // "")"' 2>/dev/null); then
            log "Cached session expired, clearing cache and re-authenticating..."
            rm -f ~/.cache/bw_session
            exec "$0" "$@"  # Re-run the script with same arguments, will go through full setup
          fi
          
          if [[ -z "$items" ]]; then
            error "No items found matching: $1"
          fi
          
          selected=$(echo "$items" | BW_SESSION="$BW_SESSION" ${pkgs.fzf}/bin/fzf \
            --delimiter='|' \
            --with-nth=1,2 \
            --preview='
              item_name="{1}"
              echo "📝 Name: $item_name"
              echo "👤 Username: {2}"
              echo ""
              echo "Loading details..."
              bw get item "$item_name" 2>/dev/null | ${pkgs.jq}/bin/jq -r "
                \"🌐 URL: \" + ((.login.uris[0].uri // \"N/A\")) + \"\n\" +
                \"📂 Folder: \" + (.folderName // \"No Folder\") + \"\n\" +
                \"🏷️  Type: \" + (if .type == 1 then \"Login\" elif .type == 2 then \"Secure Note\" elif .type == 3 then \"Card\" elif .type == 4 then \"Identity\" else \"Unknown\" end) + \"\n\" +
                (if .notes and (.notes != \"\") then \"📋 Notes: \" + .notes + \"\n\" else \"\" end) +
                (if (.login.totp // null) then \"🔐 TOTP: Available\" else \"\" end)
              " 2>/dev/null || echo "Details unavailable"
            ' \
            --preview-window=right:50% \
            --prompt="Select from '$1' results: " \
            --height=60% \
            --border)
          
          if [[ -n "$selected" ]]; then
            item_name=$(echo "$selected" | cut -d'|' -f1)
            log "Getting password for: $item_name"
            
            if password=$(bw get password "$item_name" 2>/dev/null); then
              echo -n "$password" | ${pkgs.wl-clipboard}/bin/wl-copy
              log "Password copied to clipboard!"
            else
              error "Failed to get password for '$item_name'"
            fi
          else
            log "No item selected"
          fi
          ;;
      esac

      # Note: Vault remains unlocked for convenience
      # Use 'bw lock' manually if you need to lock it
    '')
  ];
}