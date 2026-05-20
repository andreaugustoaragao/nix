{ lib, owner, ... }:

let
  # Fleet pubkeys live under secrets/ssh_pubkeys/*.pub (plaintext —
  # public keys aren't secrets). Each file is one pubkey written by
  # `nix run .#fleet-bootstrap` on the corresponding client host. We
  # glob them in here so adding a new client never requires editing
  # this file — the client runs bootstrap, pushes the .pub, every
  # NixOS host picks it up on the next rebuild.
  fleetPubkeysDir = ../secrets/ssh_pubkeys;
  fleetPubkeys =
    let
      files = builtins.filter (lib.hasSuffix ".pub") (lib.attrNames (builtins.readDir fleetPubkeysDir));
    in
    map (f: lib.fileContents "${fleetPubkeysDir}/${f}") files;
in
{
  services.openssh = {
    enable = true;
    settings = {
      # SECURITY: Disable password authentication - use SSH keys only
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      PubkeyAuthentication = true;

      # Additional SSH hardening
      MaxAuthTries = 3;
      ClientAliveInterval = 300;
      ClientAliveCountMax = 2;
      X11Forwarding = false;
      AllowTcpForwarding = "no";
      AllowStreamLocalForwarding = "no";
      GatewayPorts = "no";
      AllowUsers = [ "${owner.name}" ];
    };
    # Use extraConfig to allow authorized_keys from SOPS-managed files
    extraConfig = ''
      AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u /home/${owner.name}/.ssh/authorized_keys /home/${owner.name}/.ssh/id_rsa_personal.pub
    '';
  };

  users.users.${owner.name}.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAb7TATctV9ege4yZoT8lZpLbvtvFE/TE1B3xFwxgnE4 penguin"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIECX5xCCeHXtKMa98SL3Z6ZLDVkQdLKD7hcywXNjlWcm andrearag@gmail.com"
  ]
  ++ fleetPubkeys;
}
