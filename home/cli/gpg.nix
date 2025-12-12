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
    # Cache timeout settings
    defaultCacheTtl = 1800;      # 30 minutes
    maxCacheTtl = 7200;          # 2 hours
    # Disable SSH support - we're using regular SSH keys
    enableSshSupport = false;
    # Use proper pinentry for GPG (ksshaskpass is not compatible with GPG protocol)
    pinentry.package = pkgs.pinentry-qt;
    # Extra configuration
    extraConfig = ''
      # Allow loopback pinentry for automated operations
      allow-loopback-pinentry
      # Disable preset passphrases
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
      # Override the default ssh-agent command to set 8 hour timeout
      # -t sets default timeout (28800 = 8 hours), 0 = no timeout
      # -a sets the socket path to a consistent location
      ExecStart = lib.mkForce "${pkgs.openssh}/bin/ssh-agent -D -t 28800 -a %t/ssh-agent";
    };
  };

  # Systemd user service to add SSH keys after agent starts
  # systemd.user.services.ssh-add-keys = {
  #   Unit = {
  #     Description = "Add SSH keys to agent";
  #     After = [ "ssh-agent.service" "graphical-session.target" ];
  #     Wants = [ "ssh-agent.service" "graphical-session.target" ];
  #     ConditionPathExists = [
  #       "%h/.ssh/id_rsa_personal"
  #       "%h/.ssh/id_rsa_work"
  #     ];
  #   };
  #   Service = {
  #     Type = "oneshot";
  #     ExecStart = "${pkgs.openssh}/bin/ssh-add %h/.ssh/id_rsa_personal %h/.ssh/id_rsa_work";
  #     Environment = [ 
  #       "SSH_AUTH_SOCK=%t/ssh-agent"
  #       "SSH_ASKPASS=${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass"
  #       "DISPLAY=:0"
  #       "QT_QPA_PLATFORM=wayland"
  #     ];
  #     RemainAfterExit = true;
  #   };
  #   Install = {
  #     WantedBy = [ "graphical-session.target" ];
  #   };
  # };

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