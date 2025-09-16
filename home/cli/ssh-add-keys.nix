{ config, pkgs, lib, ... }:

{
  # Create a script to add SSH keys to the agent
  home.packages = [
    (pkgs.writeShellApplication {
      name = "ssh-add-keys";
      runtimeInputs = [ pkgs.openssh pkgs.expect ];
      text = ''
      # SSH key loading script
      # Adds personal and work SSH keys to the SSH agent only if not already loaded
      
      set -euo pipefail
      
      # Check if SSH agent is running
      if ! ssh-add -l &>/dev/null; then
        if [[ $? == 2 ]]; then
          echo "Error: SSH agent is not running" >&2
          echo "Start SSH agent first with: eval \$(ssh-agent)" >&2
          exit 1
        fi
      fi
      
      # SSH key paths
      PERSONAL_KEY="$HOME/.ssh/id_rsa_personal"
      WORK_KEY="$HOME/.ssh/id_rsa_work"
      
      # Get currently loaded key fingerprints
      LOADED_KEYS=$(ssh-add -l 2>/dev/null | cut -d' ' -f2 || true)
      
      # Function to check if a key is already loaded
      is_key_loaded() {
        local key_path="$1"
        
        if [[ ! -f "$key_path" ]]; then
          return 1
        fi
        
        # Get fingerprint of the key file
        local key_fingerprint
        key_fingerprint=$(ssh-keygen -lf "$key_path" 2>/dev/null | cut -d' ' -f2 || echo "")
        
        if [[ -z "$key_fingerprint" ]]; then
          return 1
        fi
        
        # Check if this fingerprint is in the loaded keys
        echo "$LOADED_KEYS" | grep -q "$key_fingerprint"
      }
      
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
      
      # Function to add a key if it exists and is not loaded
      add_key_if_needed() {
        local key_path="$1"
        local key_name="$2"
        local passphrase_file="$3"
        
        if [[ ! -f "$key_path" ]]; then
          echo "⚠ $key_name key not found at $key_path"
          return 0
        fi
        
        if is_key_loaded "$key_path"; then
          echo "✓ $key_name key already loaded"
          return 0
        fi
        
        echo "Adding $key_name SSH key..."
        
        # Try to get passphrase from SOPS first
        if passphrase=$(get_sops_passphrase "$passphrase_file"); then
          echo "Using SOPS-encrypted passphrase for $key_name key..."
          # Use expect to provide the passphrase automatically
          if command -v expect >/dev/null 2>&1; then
            if expect -c "
              spawn ssh-add \"$key_path\"
              expect \"Enter passphrase\"
              send \"$passphrase\r\"
              expect eof
            " >/dev/null 2>&1; then
              echo "✓ Successfully added $key_name key using SOPS passphrase"
              return 0
            fi
          else
            # Fallback: use ssh-add with stdin (less reliable)
            if echo "$passphrase" | SSH_ASKPASS=/bin/false ssh-add "$key_path" >/dev/null 2>&1; then
              echo "✓ Successfully added $key_name key using SOPS passphrase"
              return 0
            fi
          fi
          echo "⚠ SOPS passphrase failed, falling back to interactive prompt"
        fi
        
        # Fallback to interactive passphrase entry
        if ssh-add "$key_path"; then
          echo "✓ Successfully added $key_name key"
        else
          echo "✗ Failed to add $key_name key" >&2
          return 1
        fi
      }
      
      # SOPS passphrase file paths
      PERSONAL_PASSPHRASE="/run/secrets/ssh_passphrase_personal"
      WORK_PASSPHRASE="/run/secrets/ssh_passphrase_work"
      
      # Add keys only if needed
      echo "Checking SSH keys in agent..."
      
      add_key_if_needed "$PERSONAL_KEY" "personal" "$PERSONAL_PASSPHRASE"
      add_key_if_needed "$WORK_KEY" "work" "$WORK_PASSPHRASE"
      
      # Show loaded keys
      echo ""
      echo "Currently loaded SSH keys:"
      ssh-add -l || echo "No keys loaded"
      '';
    })
  ];
}