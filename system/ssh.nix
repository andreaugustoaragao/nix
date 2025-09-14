{ config, pkgs, lib, inputs, owner, ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = true;
      PermitRootLogin = "no";  # Keep root login disabled for security
    };
    # Enable SSH key authentication between machines
    authorizedKeysFiles = [
      "/home/${owner.name}/.ssh/id_rsa_personal.pub"
    ];
  };
} 