{
  lib,
  isServer,
  hostName,
  stateVersion,
  personalOnly,
  ...
}:

{
  imports = [
    ./boot.nix
    ./nix.nix
    ./packages.nix
    ./users.nix
    ./personal-isolation.nix
    ./networking.nix
    ./security.nix # Security hardening configuration
    ./env.nix
    ./nvim.nix
  ]
  ++ lib.optionals (!personalOnly) [
    ./auto-upgrade.nix
    ./matrix-alert.nix
    ./flake-update.nix
    ./ssh.nix
    ./sops.nix
  ]
  ++ lib.optionals (!isServer) [
    ./desktop.nix
    ./desktop-responsiveness.nix
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
  ++ lib.optionals (!personalOnly && hostName != "workstation" && !isServer) [
    ./loki.nix
    ./grafana.nix
  ]
  ++ lib.optionals (!personalOnly && hostName != "workstation") [
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

  # Corporate internal CAs + the MITM TLS-intercepting proxy root.
  # Required for curl/git/openssl to validate connections that go
  # through the corporate egress proxy or hit internal services.
  config.security.pki.certificateFiles = lib.optionals (!personalOnly) (
    [
      ../certs/internal-root-2.pem
      ../certs/internal-root-1.pem
      ../certs/internal-intermediate.pem
      ../certs/proxy-root.pem
      ../certs/netskope-root.pem
    ]
    ++ lib.optionals (hostName == "prl-dev-vm") [ ../certs/tracker-local-ca.pem ]
  );

}
