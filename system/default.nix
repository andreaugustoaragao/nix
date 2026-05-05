{
  config,
  pkgs,
  lib,
  inputs,
  isWorkstation,
  isLaptop,
  isVm,
  isServer,
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
    ./auto-upgrade.nix
    ./matrix-alert.nix
    ./packages.nix
    ./users.nix
    ./networking.nix
    ./ssh.nix
    ./security.nix # Security hardening configuration
    ./kmscon.nix
    ./env.nix
    ./fonts.nix
    ./nvim.nix
    ./sops.nix
  ]
  ++ lib.optionals (!isServer) [
    ./desktop.nix
    ./virtualization.nix
    ./audio.nix
    ./display-manager.nix
    ./bluetooth.nix
    ./lockscreen.nix
    ./browsers.nix
    ./printing.nix
    ./accounts.nix
  ]
  ++ lib.optionals (hostName != "workstation" && !isServer) [
    ./loki.nix
    ./grafana.nix
  ]
  ++ lib.optionals (hostName != "workstation") [
    ./caddy.nix
  ]
  ++ lib.optionals isServer [
    ./server
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
