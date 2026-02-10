{
  config,
  pkgs,
  lib,
  inputs,
  isWorkstation,
  isLaptop,
  isVm,
  owner,
  hostName,
  stateVersion,
  profile,
  bluetooth ? false,
  lockScreen ? false,
  ...
}:

{
  imports = [
    ./boot.nix
    ./nix.nix
    ./packages.nix
    ./desktop.nix
    ./virtualization.nix
    ./audio.nix
    ./display-manager.nix
    ./users.nix
    ./networking.nix
    ./ssh.nix
    ./security.nix  # Security hardening configuration
    ./kmscon.nix
    ./env.nix
    ./fonts.nix
    ./nvim.nix
    ./sops.nix
    ./bluetooth.nix
    ./lockscreen.nix
  ];

  config = {
    # Set hostname and state version from metadata
    networking.hostName = hostName;
    system.stateVersion = stateVersion;

    # Common configuration
    time.timeZone = "America/Denver";
    i18n.defaultLocale = "en_US.UTF-8";
  };

  config.security.pki.certificateFiles = [
    ../certs/avayaitrootca2.pem
    ../certs/avayaitrootca.pem
    ../certs/avayaitserverca2.pem
    ../certs/zscalerrootcertificate-2048-sha256.pem
  ];

}
