{
  config,
  lib,
  hostAddress,
  ...
}:

let
  cfg = config.my.kubernetes.network;
in
{
  options.my.kubernetes.network = {
    gateway = lib.mkOption {
      type = lib.types.str;
      default = "10.211.55.1";
      description = "IPv4 gateway for the dedicated cluster VM.";
    };
    prefixLength = lib.mkOption {
      type = lib.types.ints.between 1 32;
      default = 24;
      description = "IPv4 prefix length for the cluster VM interface.";
    };
    nameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "10.211.55.1" ];
      description = "DNS servers reachable from the cluster VM.";
    };
    clientNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "10.211.55.0/24" ];
      description = "IPv4 networks allowed to reach SSH, ingress, the API, and the registry.";
    };
  };

  config = {
    # Reserve this address in the Parallels Shared Network before installation.
    # Its value lives in machines.toml and is also used by the client helpers.
    networking = {
      useNetworkd = true;
      useDHCP = false;
      firewall = {
        enable = true;
        checkReversePath = "loose";
        trustedInterfaces = [
          "cni0"
          "flannel.1"
        ];
        # Single-node cluster: no external VXLAN, etcd, or kubelet ports.
        # Kubernetes service forwarding is managed separately by kube-proxy.
        extraCommands = lib.concatMapStringsSep "\n" (network: ''
          iptables -A nixos-fw -s ${lib.escapeShellArg network} -p tcp -m multiport --dports 22,80,443,6443 -j nixos-fw-accept
        '') cfg.clientNetworks;
      };
    };

    systemd.network = {
      enable = true;
      networks = {
        "10-ethernet" = {
          matchConfig.Name = "en*";
          networkConfig = {
            Address = "${hostAddress}/${toString cfg.prefixLength}";
            Gateway = cfg.gateway;
            DNS = cfg.nameservers;
            IPv6AcceptRA = false;
          };
        };
        "01-container-interfaces" = {
          matchConfig.Name = [
            "veth*"
            "cni*"
            "flannel*"
          ];
          linkConfig.Unmanaged = true;
        };
      };
    };
    services.resolved.enable = true;
  };
}
