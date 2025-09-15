{ config, pkgs, lib, ... }:

{
  # Custom SSH askpass script that reads passphrases from SOPS
  home.file.".local/bin/ssh-askpass-sops" = {
    text = ''
      #!${pkgs.bash}/bin/bash
      
      # SSH askpass script that reads passphrases from SOPS secrets
      # Usage: This script is called by ssh-add when SSH_ASKPASS is set
      
      # The prompt passed by ssh-add contains information about which key
      PROMPT="$1"
      
      # Default fallback to GUI askpass if we can't determine the key
      GUI_ASKPASS="${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass"
      
      # Function to safely read from SOPS file
      read_sops_secret() {
        local secret_file="$1"
        if [[ -f "$secret_file" ]] && [[ -r "$secret_file" ]]; then
          local content=$(cat "$secret_file" 2>/dev/null)
          # Check if it's not a placeholder
          if [[ -n "$content" ]] && [[ "$content" != "placeholder" ]]; then
            echo "$content"
            return 0
          fi
        fi
        return 1
      }
      
      # Try to determine which key is being requested based on the prompt
      case "$PROMPT" in
        *"id_rsa_personal"*|*"personal"*)
          if passphrase=$(read_sops_secret "/run/secrets/ssh_passphrase_personal"); then
            echo "$passphrase"
            exit 0
          fi
          ;;
        *"id_rsa_work"*|*"work"*)
          if passphrase=$(read_sops_secret "/run/secrets/ssh_passphrase_work"); then
            echo "$passphrase"
            exit 0
          fi
          ;;
        *)
          # For unknown keys, try both passphrases or fall back to GUI
          if passphrase=$(read_sops_secret "/run/secrets/ssh_passphrase_personal"); then
            echo "$passphrase"
            exit 0
          elif passphrase=$(read_sops_secret "/run/secrets/ssh_passphrase_work"); then
            echo "$passphrase"
            exit 0
          fi
          ;;
      esac
      
      # Fallback to GUI askpass if SOPS secrets are not available or don't work
      if [[ -n "$DISPLAY" ]] || [[ -n "$WAYLAND_DISPLAY" ]]; then
        exec "$GUI_ASKPASS" "$PROMPT"
      else
        # Last resort: use built-in read (for headless environments)
        echo -n "Enter passphrase for $PROMPT: " >&2
        read -s passphrase
        echo >&2  # newline
        echo "$passphrase"
      fi
    '';
    executable = true;
  };
}