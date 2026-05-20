{
  lib,
  isServer,
  hostName,
  stateVersion,
  ...
}:

{
  imports = [
    ./boot.nix
    ./nix.nix
    ./auto-upgrade.nix
    ./matrix-alert.nix
    ./flake-update.nix
    ./packages.nix
    ./users.nix
    ./networking.nix
    ./ssh.nix
    ./security.nix # Security hardening configuration
    ./env.nix
    ./nvim.nix
    ./sops.nix
    # mDNS / Bonjour — every host in the flake advertises
    # <hostname>.local and resolves peers the same way.
    ./mdns.nix
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
    ./kmscon.nix
    ./fonts.nix
  ]
  ++ lib.optionals (hostName != "workstation" && !isServer) [
    ./loki.nix
    ./grafana.nix
  ]
  ++ lib.optionals (hostName != "workstation") [
    ./caddy.nix
    # Workstation runs chroma as a sidecar of the upstream fulcrum
    # docker-compose.yml; every other host that runs fulcrum from
    # source needs us to bring up chroma declaratively.
    ./chroma.nix
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
