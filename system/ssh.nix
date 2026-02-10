{ config, pkgs, lib, inputs, owner, ... }:

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
      AuthorizedKeysFile /home/${owner.name}/.ssh/authorized_keys /home/${owner.name}/.ssh/id_rsa_personal.pub
    '';
  };
} 