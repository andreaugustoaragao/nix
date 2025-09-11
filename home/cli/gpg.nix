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

  # GPG Agent configuration
  services.gpg-agent = {
    enable = true;
    # Cache timeout settings
    defaultCacheTtl = 1800;      # 30 minutes
    maxCacheTtl = 7200;          # 2 hours
    # Enable SSH support
    enableSshSupport = true;
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

  # Install GPG-related packages
  home.packages = with pkgs; [
    gnupg
    pinentry-gtk2
    paperkey  # For backing up GPG keys to paper
  ];
}