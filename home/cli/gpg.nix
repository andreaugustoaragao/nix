{ config, pkgs, lib, inputs, owner, ... }:

{
  # GPG configuration with secure settings
  programs.gpg = {
    enable = true;
    settings = {
      # Use AES256 for symmetric encryption
      cipher-algo = "AES256";
      # Use SHA512 for hashing
      digest-algo = "SHA512";
      # Use SHA512 for certifications
      cert-digest-algo = "SHA512";
      # Disable weak digest algorithms
      weak-digest = "SHA1";
      # Use stronger compression
      compress-algo = "2";
      # Disable inclusion of version in output
      no-emit-version = true;
      # Disable comments in output
      no-comments = true;
      # Use long keyids
      keyid-format = "0xlong";
      # Show fingerprints
      with-fingerprint = true;
      # Cross-certify subkeys
      require-cross-certification = true;
      # Use gpg-agent
      use-agent = true;
    };
  };

  # GPG Agent configuration (for signing only, not SSH)
  services.gpg-agent = {
    enable = true;
    # Cache timeout settings (long TTL for unattended agent operations)
    defaultCacheTtl = 43200;     # 12 hours
    maxCacheTtl = 43200;         # 12 hours
    # Disable SSH support - we're using regular SSH keys
    enableSshSupport = false;
    # Use proper pinentry for GPG (ksshaskpass is not compatible with GPG protocol)
    pinentry.package = pkgs.pinentry-qt;
    # Extra configuration
    extraConfig = ''
      # Allow loopback pinentry for automated operations
      allow-loopback-pinentry
      # Allow gpg-preset-passphrase to cache passphrases indefinitely
      allow-preset-passphrase
      # Disable external cache
      no-allow-external-cache
    '';
  };

  # SSH agent configuration with extended timeout
  services.ssh-agent = {
    enable = true;
  };
  
  # Override SSH agent service to add timeout configuration and consistent socket path
  systemd.user.services.ssh-agent = {
    Service = {
      # Override the default ssh-agent command with no timeout for unattended agents
      # -t 0 = keys never expire, -a sets consistent socket path
      ExecStart = lib.mkForce "${pkgs.openssh}/bin/ssh-agent -D -t 0 -a %t/ssh-agent";
    };
  };

  # Auto-preset GPG passphrases after gpg-agent starts
  systemd.user.services.gpg-preset-keys = {
    Unit = {
      Description = "Preset GPG passphrases from SOPS secrets";
      After = [ "gpg-agent.service" "sops-nix.service" ];
      Wants = [ "gpg-agent.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
      ExecStart = "${pkgs.writeShellScript "gpg-preset-keys" ''
        export PATH="${lib.makeBinPath [ pkgs.gnupg pkgs.gawk pkgs.coreutils ]}:$PATH"
        LIBEXEC="${pkgs.gnupg}/libexec"

        preset_key() {
          local email="$1" passphrase_file="$2"
          [[ -f "$passphrase_file" ]] || return 0
          local passphrase
          passphrase=$(cat "$passphrase_file" 2>/dev/null)
          [[ -n "$passphrase" && "$passphrase" != "placeholder" ]] || return 0
          gpg --list-secret-keys "$email" >/dev/null 2>&1 || return 0
          gpg --list-secret-keys --with-colons --with-keygrip "$email" \
            | awk -F: '/^grp:/ {print $10}' \
            | while IFS= read -r grip; do
                "$LIBEXEC/gpg-preset-passphrase" --preset --passphrase "$passphrase" "$grip"
              done
        }

        preset_key "andrearag@gmail.com" "/run/secrets/gpg_passphrase_personal"
        preset_key "aragao@avaya.com" "/run/secrets/gpg_passphrase_work"
      ''}";
      RemainAfterExit = true;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # SSH configuration with sops-sourced identity files
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    
    # Default configuration for personal machines
    extraConfig = ''
      # Enable SSH agent forwarding
      ForwardAgent yes
    '';
    
    # GitHub configurations using sops-managed SSH keys
    matchBlocks = {
      "*" = {
        # Default SSH settings for all hosts
        addKeysToAgent = "yes";
        compression = true;
        serverAliveInterval = 60;
        serverAliveCountMax = 3;
      };
      
      "github-personal" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_rsa_personal";  # From sops
        identitiesOnly = true;
      };
      
      "github-work" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_rsa_work";     # From sops
        identitiesOnly = true;
      };
    };
  };

  # Environment setup for SOPS age key and SSH agent
  home.sessionVariables = {
    SOPS_AGE_KEY_FILE = "/home/${owner.name}/.ssh/id_ed25519_nixos-agenix";
    SSH_ASKPASS = "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass";
    SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/ssh-agent";
  };
  
  # Shell initialization to ensure SOPS age key and SSH askpass are available
  programs.bash.initExtra = ''
    export SOPS_AGE_KEY_FILE="/home/${owner.name}/.ssh/id_ed25519_nixos-agenix"
    export SSH_ASKPASS="${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass"
    export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent"
  '';

  programs.fish.interactiveShellInit = ''
    set -gx SOPS_AGE_KEY_FILE "/home/${owner.name}/.ssh/id_ed25519_nixos-agenix"
    set -gx SSH_ASKPASS "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass"
    set -gx SSH_AUTH_SOCK "$XDG_RUNTIME_DIR/ssh-agent"
  '';

  programs.zsh.initContent = lib.mkBefore ''
    export SOPS_AGE_KEY_FILE="/home/${owner.name}/.ssh/id_ed25519_nixos-agenix"
    export SSH_ASKPASS="${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass"
    export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent"
  '';

  # Install GPG-related packages
  home.packages = with pkgs; [
    gnupg
    paperkey  # For backing up GPG keys to paper
    kdePackages.ksshaskpass  # For SSH passphrase prompts in GUI
    pinentry-qt  # For GPG passphrase prompts in GUI
  ];

  # Auto-import GPG keys from sops-managed secrets (if available)
  home.activation.importGPG = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # Import personal GPG key if it exists and is not a placeholder
    GPG_PERSONAL="/run/secrets/gpg_key_personal"
    if [[ -f "$GPG_PERSONAL" ]] && [[ "$(cat $GPG_PERSONAL)" != "placeholder" ]]; then
      ${pkgs.gnupg}/bin/gpg --batch --import "$GPG_PERSONAL" 2>/dev/null || true
      # Set ultimate trust for imported personal key
      PERSONAL_KEYID=$(${pkgs.gnupg}/bin/gpg --list-keys --with-colons andrearag@gmail.com | ${pkgs.gawk}/bin/awk -F: '/^pub:/ {print $5}' | ${pkgs.coreutils}/bin/head -1)
      if [[ -n "$PERSONAL_KEYID" ]]; then
        echo "$PERSONAL_KEYID:6:" | ${pkgs.gnupg}/bin/gpg --batch --import-ownertrust 2>/dev/null || true
      fi
    fi
    
    # Import work GPG key if it exists and is not a placeholder  
    GPG_WORK="/run/secrets/gpg_key_work"
    if [[ -f "$GPG_WORK" ]] && [[ "$(cat $GPG_WORK)" != "placeholder" ]]; then
      ${pkgs.gnupg}/bin/gpg --batch --import "$GPG_WORK" 2>/dev/null || true
      # Set ultimate trust for imported work key
      WORK_KEYID=$(${pkgs.gnupg}/bin/gpg --list-keys --with-colons aragao@avaya.com | ${pkgs.gawk}/bin/awk -F: '/^pub:/ {print $5}' | ${pkgs.coreutils}/bin/head -1)
      if [[ -n "$WORK_KEYID" ]]; then
        echo "$WORK_KEYID:6:" | ${pkgs.gnupg}/bin/gpg --batch --import-ownertrust 2>/dev/null || true
      fi
    fi
  '';
}