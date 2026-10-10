{
  pkgs,
  hostName,
  stateVersion,
  ...
}:

{
  imports = [
    ./access.nix
    ./networking.nix
    ./k3s.nix
    ./registry.nix
  ];

  networking.hostName = hostName;
  system.stateVersion = stateVersion;
  time.timeZone = "America/Denver";
  i18n.defaultLocale = "en_US.UTF-8";

  # This profile deliberately has no Home Manager, SOPS, desktop services,
  # automatic remote activation, or Parallels file/clipboard integration.
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    sandbox = true;
    trusted-users = [ "root" ];
    cores = 4;
    max-jobs = 2;
    auto-optimise-store = true;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    jq
    rsync
    kubectl
    kubernetes-helm
    k9s
  ];

  # Public trust anchors for corporate registries and internal services.
  security.pki.certificateFiles = [
    ../../certs/internal-root-2.pem
    ../../certs/internal-root-1.pem
    ../../certs/internal-intermediate.pem
    ../../certs/proxy-root.pem
    ../../certs/netskope-root.pem
  ];

  services.timesyncd.enable = true;
  systemd.coredump.enable = false;
}
