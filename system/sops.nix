{
  config,
  pkgs,
  lib,
  inputs,
  owner,
  isServer,
  ...
}:

{
  # Install sops package system-wide
  environment.systemPackages = with pkgs; [ sops ];

  # sops-nix configuration
  sops = {
    # Default sops file location
    defaultSopsFile = ../secrets/secrets.yaml;

    # Validate sops files at build time
    validateSopsFiles = true; # Set to true once you have secrets file

    # Age key configuration
    age = {
      # Path to age key for decryption - use metadata owner name
      keyFile = "/var/lib/sops-nix/key.txt";
      # Generate host key automatically if it doesn't exist
      generateKey = true;
    };

    # Secret definitions
    secrets = {
      # User passwords (commented out for initial setup)
      "user_password" = {
        owner = "root";
        group = "root";
        mode = "0400";
        neededForUsers = true;
      };

      "root_password" = {
        owner = "root";
        group = "root";
        mode = "0400";
        neededForUsers = true;
      };

      # SSH keys for GitHub
      "ssh_key_github_work" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
        path = "/home/${owner.name}/.ssh/id_rsa_work";
      };

      "ssh_key_github_personal" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
        path = "/home/${owner.name}/.ssh/id_rsa_personal";
      };

      # SSH public keys (for reference/automation)
      "ssh_pubkey_github_work" = {
        owner = owner.name;
        group = "users";
        mode = "0444";
        path = "/home/${owner.name}/.ssh/id_rsa_work.pub";
      };

      "ssh_pubkey_github_personal" = {
        owner = owner.name;
        group = "users";
        mode = "0444";
        path = "/home/${owner.name}/.ssh/id_rsa_personal.pub";
      };

      # GPG keys for signing/encryption
      "gpg_key_personal" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };

      "gpg_key_work" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };

      # SSH key passphrases for automatic loading
      "ssh_passphrase_personal" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };

      "ssh_passphrase_work" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };

      # GPG key passphrases for automatic unlocking
      "gpg_passphrase_personal" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };

      "gpg_passphrase_work" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };

      # WiFi environment file for wpa_supplicant
      "wifi_env" = {
        owner = "root";
        group = "root";
        mode = "0600";
        path = "/run/secrets/wifi_env";
      };

      # Matrix bot credentials — used by system/matrix-alert.nix and
      # system/auto-upgrade.nix to post failure alerts and upgrade
      # diffs to the alert room on matrix.faragao.net (homeserver
      # runs on maui). Loaded into units via systemd LoadCredential.
      #
      # bot_token is also consumed by the user-mode Fulcrum service
      # (home/services/fulcrum.nix) via MATRIX_ACCESS_TOKEN_FILE, so
      # we make it readable by the owner user. The systemd alert paths
      # work the same way — LoadCredential copies into the unit's private
      # credentials directory regardless of source file ownership.
      "matrix/bot_token" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };
      "matrix/alert_room_id" = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
    }
    // lib.optionalAttrs (!isServer) {
      # Bitwarden + Google OAuth — only consumed by the user's
      # graphical session (Bitwarden CLI/Google Workspace MCP).
      # No client on a headless server, so don't materialize.
      "bitwarden/master_password" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };
      "bitwarden/server_url" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };
      "bitwarden/email" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };
      "google_oauth_client_id" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };
      "google_oauth_client_secret" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };
    }
    // lib.optionalAttrs isServer {
      # ACME — Cloudflare API token for DNS-01 challenge.
      # File contents: CLOUDFLARE_DNS_API_TOKEN=<token>
      "cloudflare_dns_token" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "acme-faragao.net.service" ];
      };

      # LLDAP admin password. Read directly by lldap (via
      # services.lldap.settings.ldap_user_pass_file) and by Authelia
      # (via AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE). Must
      # contain exactly the password bytes (no trailing newline).
      "lldap/admin_password" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [
          "lldap.service"
          "authelia-main.service"
        ];
      };

      # Authelia secrets — all consumed via LoadCredential by the
      # authelia-main systemd unit, so root ownership is fine.
      "authelia/jwt_secret" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "authelia-main.service" ];
      };
      "authelia/storage_encryption_key" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "authelia-main.service" ];
      };
      "authelia/session_secret" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "authelia-main.service" ];
      };
      "authelia/hmac_secret" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "authelia-main.service" ];
      };
      # OIDC issuer private key — RSA PEM. Generate with:
      #   openssl genrsa -out issuer.pem 4096
      "authelia/jwt_private_key" = {
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "authelia-main.service" ];
      };
    };
  };

  users.users.${owner.name} = lib.mkMerge [
    # Default configuration with fallback password for initial installation
    {
      initialPassword = "changeme"; # Change after first boot and sops setup
    }
    # Override with sops password file when available
    (lib.mkIf (builtins.pathExists config.sops.secrets.user_password.path) {
      hashedPasswordFile = config.sops.secrets.user_password.path;
      initialPassword = lib.mkForce null;
    })
  ];

  users.users.root = lib.mkMerge [
    # Default configuration with fallback password for initial installation
    {
      initialPassword = "changeme"; # Change after first boot and sops setup
    }
    # Override with sops password file when available
    (lib.mkIf (builtins.pathExists config.sops.secrets.root_password.path) {
      hashedPasswordFile = config.sops.secrets.root_password.path;
      initialPassword = lib.mkForce null;
    })
  ];

  # Ensure SSH directory exists with proper permissions
  system.activationScripts.sops-ssh-setup = lib.stringAfter [ "users" ] ''
    # Create .ssh directory for ${owner.name} if it doesn't exist
    mkdir -p /home/${owner.name}/.ssh
    chown ${owner.name}:users /home/${owner.name}/.ssh
    chmod 700 /home/${owner.name}/.ssh
  '';
}
