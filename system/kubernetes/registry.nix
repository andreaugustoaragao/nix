{ pkgs, hostAddress, ... }:

let
  registries = pkgs.writeText "k3s-registries.json" (
    builtins.toJSON {
      mirrors = {
        "localhost:5000".endpoint = [ "http://127.0.0.1:5000" ];
        "${hostAddress}:5000".endpoint = [ "http://${hostAddress}:5000" ];
      };
    }
  );
in
{
  # Persistent registry managed independently of Kubernetes and containerd.
  # This is the existing unauthenticated development registry, reachable
  # only through the Parallels subnet firewall rule or local loopback.
  services.dockerRegistry = {
    enable = true;
    listenAddress = "0.0.0.0";
    port = 5000;
    storagePath = "/var/lib/docker-registry";
    openFirewall = false;
  };

  systemd.services.docker-registry.serviceConfig = {
    Restart = "on-failure";
    NoNewPrivileges = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ReadWritePaths = [ "/var/lib/docker-registry" ];
    PrivateTmp = true;
  };

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -s 10.211.55.0/24 -p tcp --dport 5000 -j nixos-fw-accept
  '';

  # Preserve existing image names used by local builds and manifests.
  environment.etc."rancher/k3s/registries.yaml".source = registries;
  systemd.services.k3s.restartTriggers = [ registries ];
}
