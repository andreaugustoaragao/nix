{
  config,
  pkgs,
  lib,
  inputs,
  owner,
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
      keyFile = "/home/${owner.name}/.ssh/id_ed25519_nixos-agenix";
      # Generate host key automatically if it doesn't exist
      generateKey = true;
    };

    # Secret definitions
    secrets = {
      # User passwords (commented out for initial setup)
      "user_password" = {
        owner = owner.name;
        group = "users";
        mode = "0400";
      };

      "root_password" = {
        owner = "root";
        group = "root";
        mode = "0400";
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
    };
  };

  users.users.${owner.name} = {
    hashedPasswordFile = config.sops.secrets.user_password.path;
  };

  users.users.root = {
    hashedPasswordFile = config.sops.secrets.root_password.path;
  };

  # Ensure SSH directory exists with proper permissions
  system.activationScripts.sops-ssh-setup = lib.stringAfter [ "users" ] ''
    # Create .ssh directory for ${owner.name} if it doesn't exist
    mkdir -p /home/${owner.name}/.ssh
    chown ${owner.name}:users /home/${owner.name}/.ssh
    chmod 700 /home/${owner.name}/.ssh
  '';
}
