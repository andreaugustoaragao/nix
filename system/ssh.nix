{ config, pkgs, lib, inputs, owner, ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = true;
      PermitRootLogin = "no";  # Keep root login disabled for security
    };
    # Use extraConfig to allow authorized_keys from SOPS-managed files
    extraConfig = ''
      AuthorizedKeysFile /home/${owner.name}/.ssh/authorized_keys /home/${owner.name}/.ssh/id_rsa_personal.pub
    '';
  };
} 