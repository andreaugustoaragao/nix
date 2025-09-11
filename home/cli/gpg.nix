{ config, pkgs, lib, inputs, ... }:

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

  # GPG Agent configuration with SSH support
  services.gpg-agent = {
    enable = true;
    # Cache timeout settings
    defaultCacheTtl = 1800;      # 30 minutes
    maxCacheTtl = 7200;          # 2 hours
    # Enable SSH support for GitHub authentication
    enableSshSupport = true;
    # Configure SSH keys from GPG authentication subkeys
    sshKeys = [
      "13128BA224F28F0BF32C4015BB454EA017882BE4"  # Authentication subkey for aragao@avaya.com
      # Note: andrearag@gmail.com key doesn't have an authentication subkey yet
      # You may need to add an authentication subkey to that GPG key
    ];
    # Pin entry program for GUI password prompts
    pinentry.package = pkgs.pinentry-gtk2;
    # Extra configuration
    extraConfig = ''
      # Allow loopback pinentry for automated operations
      allow-loopback-pinentry
      # Disable preset passphrases
      no-allow-external-cache
    '';
  };

  # SSH configuration to work with GPG agent
  programs.ssh = {
    enable = true;
    
    # Use GPG agent for SSH authentication
    extraConfig = ''
      # Use GPG agent for SSH authentication
      IdentityAgent "''${XDG_RUNTIME_DIR}/gnupg/S.gpg-agent.ssh"
      
      # GitHub configuration
      Host github.com
        HostName github.com
        User git
        PreferredAuthentications publickey
    '';
    
    # Default SSH settings
    compression = true;
    serverAliveInterval = 60;
    serverAliveCountMax = 3;
  };

  # Environment setup for SSH with GPG agent
  home.sessionVariables = {
    SSH_AUTH_SOCK = "$(gpgconf --list-dirs agent-ssh-socket)";
  };
  
  # Shell initialization to ensure SSH_AUTH_SOCK is set properly
  programs.bash.initExtra = ''
    export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
  '';
  
  programs.fish.interactiveShellInit = ''
    set -gx SSH_AUTH_SOCK (gpgconf --list-dirs agent-ssh-socket)
  '';
  
  programs.zsh.initContent = lib.mkBefore ''
    export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
  '';

  # Install GPG-related packages
  home.packages = with pkgs; [
    gnupg
    pinentry-gtk2
    paperkey  # For backing up GPG keys to paper
  ];
}