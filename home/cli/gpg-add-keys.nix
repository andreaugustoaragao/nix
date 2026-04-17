{ config, pkgs, lib, ... }:

{
  # Create a script to preload GPG keys into the agent cache
  home.packages = [
    (pkgs.writeShellApplication {
      name = "gpg-add-keys";
      runtimeInputs = with pkgs; [ gnupg gawk coreutils ];
      text = ''
        # GPG key preloading script
        # Uses gpg-preset-passphrase to cache passphrases indefinitely
        # (until gpg-agent restarts). Requires allow-preset-passphrase in
        # gpg-agent.conf.

        set -euo pipefail

        LIBEXEC="${pkgs.gnupg}/libexec"

        # Read passphrase from a SOPS-decrypted file
        get_sops_passphrase() {
          local passphrase_file="$1"
          if [[ -f "$passphrase_file" ]] && [[ -r "$passphrase_file" ]]; then
            local content
            content=$(cat "$passphrase_file" 2>/dev/null)
            if [[ -n "$content" ]] && [[ "$content" != "placeholder" ]]; then
              echo "$content"
              return 0
            fi
          fi
          return 1
        }

        # Get keygrips for all secret subkeys of a given email
        get_keygrips() {
          local email="$1"
          gpg --list-secret-keys --with-colons --with-keygrip "$email" 2>/dev/null \
            | awk -F: '/^grp:/ {print $10}'
        }

        # Preset passphrase for all keygrips of a key
        preset_key() {
          local key_email="$1"
          local key_name="$2"
          local passphrase_file="$3"

          if ! gpg --list-secret-keys "$key_email" >/dev/null 2>&1; then
            echo "-- $key_name GPG key not found for $key_email"
            return 0
          fi

          local passphrase
          if ! passphrase=$(get_sops_passphrase "$passphrase_file"); then
            echo "-- No SOPS passphrase available for $key_name key, skipping preset"
            return 0
          fi

          local keygrips
          keygrips=$(get_keygrips "$key_email")

          if [[ -z "$keygrips" ]]; then
            echo "-- Could not determine keygrips for $key_name key"
            return 0
          fi

          local count=0
          while IFS= read -r grip; do
            "$LIBEXEC/gpg-preset-passphrase" --preset --passphrase "$passphrase" "$grip"
            count=$((count + 1))
          done <<< "$keygrips"

          echo "ok $key_name GPG key preset ($count keygrips cached indefinitely)"
        }

        # SOPS passphrase file paths
        PERSONAL_PASSPHRASE="/run/secrets/gpg_passphrase_personal"
        WORK_PASSPHRASE="/run/secrets/gpg_passphrase_work"

        echo "Presetting GPG passphrases..."
        preset_key "andrearag@gmail.com" "personal" "$PERSONAL_PASSPHRASE"
        preset_key "aragao@avaya.com" "work" "$WORK_PASSPHRASE"

        # Show cache status
        echo ""
        cached_count=$(gpg-connect-agent 'keyinfo --list' /bye 2>/dev/null | grep -c "KEYINFO" || echo "0")
        echo "Keys in GPG agent cache: $cached_count"
        echo "Done. Passphrases will persist until gpg-agent restarts."
      '';
    })
  ];
}