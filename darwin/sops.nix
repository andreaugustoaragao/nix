{
  pkgs,
  owner,
  homePrefix,
  ...
}:

{
  environment.systemPackages = [ pkgs.sops ];

  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;
    validateSopsFiles = true;

    # On Darwin we don't have a system ssh host key the same way NixOS
    # does, so sops-nix reads an age identity file directly. Generate
    # this once (see SOPS-SETUP-GUIDE.md) and stash the pubkey in
    # keys/<host>.age.pub.
    age = {
      keyFile = "${homePrefix}/${owner.name}/.config/sops/age/keys.txt";
      generateKey = false; # generated out-of-band, see guide
      # Suppress the default probe of /etc/ssh/ssh_host_ed25519_key as
      # a fallback age identity — doesn't exist on macOS.
      sshKeyPaths = [ ];
    };

    # Likewise for the legacy "derive a GPG identity from the SSH host
    # key" path, which defaults to /etc/ssh/ssh_host_rsa_key. We have
    # no use for it and don't run sshd here.
    gnupg.sshKeyPaths = [ ];

    # Mirror the user-facing secrets from system/sops.nix so the same
    # decrypted paths exist on Darwin. Server-only secrets are omitted.
    secrets = {
      ssh_key_github_work = {
        owner = owner.name;
        mode = "0400";
        path = "${homePrefix}/${owner.name}/.ssh/id_rsa_work";
      };
      ssh_key_github_personal = {
        owner = owner.name;
        mode = "0400";
        path = "${homePrefix}/${owner.name}/.ssh/id_rsa_personal";
      };
      ssh_pubkey_github_work = {
        owner = owner.name;
        mode = "0444";
        path = "${homePrefix}/${owner.name}/.ssh/id_rsa_work.pub";
      };
      ssh_pubkey_github_personal = {
        owner = owner.name;
        mode = "0444";
        path = "${homePrefix}/${owner.name}/.ssh/id_rsa_personal.pub";
      };

      gpg_key_personal = {
        owner = owner.name;
        mode = "0400";
      };
      gpg_key_work = {
        owner = owner.name;
        mode = "0400";
      };

      ssh_passphrase_personal = {
        owner = owner.name;
        mode = "0400";
      };
      ssh_passphrase_work = {
        owner = owner.name;
        mode = "0400";
      };
      gpg_passphrase_personal = {
        owner = owner.name;
        mode = "0400";
      };
      gpg_passphrase_work = {
        owner = owner.name;
        mode = "0400";
      };

      "bitwarden/master_password" = {
        owner = owner.name;
        mode = "0400";
      };
      "bitwarden/server_url" = {
        owner = owner.name;
        mode = "0400";
      };
      "bitwarden/email" = {
        owner = owner.name;
        mode = "0400";
      };
      litellm_api_key = {
        owner = owner.name;
        mode = "0400";
      };
      anthropic_api_key = {
        owner = owner.name;
        mode = "0400";
      };
    };
  };

  # nix-darwin doesn't surface `users.users.<name>.uid` the way NixOS
  # does, but sops-nix needs the ssh dir to exist before it writes
  # `id_rsa_*` into it.
  system.activationScripts.sops-ssh-setup.text = ''
    mkdir -p ${homePrefix}/${owner.name}/.ssh
    chown ${owner.name}:staff ${homePrefix}/${owner.name}/.ssh
    chmod 700 ${homePrefix}/${owner.name}/.ssh
  '';
}
