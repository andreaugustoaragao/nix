{ config, pkgs, lib, inputs, ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = true;
      PermitRootLogin = "no";  # Keep root login disabled for security
    };
  };
} 