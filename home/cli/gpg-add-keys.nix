{ config, pkgs, lib, ... }:

{
  # Create a script to preload GPG keys into the agent cache
  home.packages = [
    (pkgs.writeShellApplication {
      name = "gpg-add-keys";
      runtimeInputs = [ pkgs.gnupg ];
      text = ''
        # GPG key preloading script
        # Unlocks personal and work GPG keys using SOPS-encrypted passphrases
        
        set -euo pipefail
        
        # Function to read passphrase from SOPS
        get_sops_passphrase() {
          local passphrase_file="$1"
          
          if [[ -f "$passphrase_file" ]] && [[ -r "$passphrase_file" ]]; then
            local content
            content=$(cat "$passphrase_file" 2>/dev/null)
            # Check if it's not a placeholder
            if [[ -n "$content" ]] && [[ "$content" != "placeholder" ]]; then
              echo "$content"
              return 0
            fi
          fi
          return 1
        }
        
        # Function to check if a GPG key is already cached
        is_gpg_key_cached() {
          local key_id="$1"
          
          # Check if the key is in the cache by trying to use it without a passphrase
          if echo "test" | gpg --batch --pinentry-mode loopback --passphrase "" --clearsign --local-user "$key_id" >/dev/null 2>&1; then
            return 0
          else
            return 1
          fi
        }
        
        # Function to preload a GPG key if it exists and is not cached
        preload_key_if_needed() {
          local key_email="$1"
          local key_name="$2"  
          local passphrase_file="$3"
          
          # Check if the key exists
          if ! gpg --list-secret-keys "$key_email" >/dev/null 2>&1; then
            echo "⚠ $key_name GPG key not found for $key_email"
            return 0
          fi
          
          # Get the key ID
          local key_id
          key_id=$(gpg --list-secret-keys --with-colons "$key_email" | awk -F: '/^sec:/ {print $5}' | head -1)
          
          if [[ -z "$key_id" ]]; then
            echo "⚠ Could not determine key ID for $key_name key"
            return 0
          fi
          
          # Check if already cached
          if is_gpg_key_cached "$key_id"; then
            echo "✓ $key_name GPG key already cached"
            return 0
          fi
          
          echo "Preloading $key_name GPG key..."
          
          # Try to get passphrase from SOPS
          if passphrase=$(get_sops_passphrase "$passphrase_file"); then
            echo "Using SOPS-encrypted passphrase for $key_name GPG key..."
            
            # Preload the key by signing a test message
            if echo "test" | gpg --batch --pinentry-mode loopback --passphrase "$passphrase" --clearsign --local-user "$key_email" >/dev/null 2>&1; then
              echo "✓ Successfully preloaded $key_name GPG key using SOPS passphrase"
              return 0
            else
              echo "⚠ SOPS passphrase failed for $key_name key, falling back to interactive prompt"
            fi
          fi
          
          # Fallback to interactive passphrase entry
          echo "Prompting for $key_name GPG key passphrase..."
          if echo "test" | gpg --clearsign --local-user "$key_email" >/dev/null 2>&1; then
            echo "✓ Successfully preloaded $key_name GPG key"
          else
            echo "✗ Failed to preload $key_name GPG key"
            return 1
          fi
        }
        
        # SOPS passphrase file paths
        PERSONAL_PASSPHRASE="/run/secrets/gpg_passphrase_personal"
        WORK_PASSPHRASE="/run/secrets/gpg_passphrase_work"
        
        # GPG key email addresses
        PERSONAL_EMAIL="andrearag@gmail.com"
        WORK_EMAIL="aragao@avaya.com"
        
        echo "Checking GPG key cache status..."
        
        # Preload keys if needed
        preload_key_if_needed "$PERSONAL_EMAIL" "personal" "$PERSONAL_PASSPHRASE"
        preload_key_if_needed "$WORK_EMAIL" "work" "$WORK_PASSPHRASE"
        
        # Show basic cache status without exposing key fingerprints
        echo ""
        echo "GPG key cache status:"
        cached_count=$(gpg-connect-agent 'keyinfo --list' /bye 2>/dev/null | grep -c "KEYINFO" || echo "0")
        echo "Keys in GPG agent cache: $cached_count"
        
        echo ""
        echo "GPG key preloading completed"
      '';
    })
  ];
}