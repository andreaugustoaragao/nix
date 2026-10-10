{ hostAddress, ... }:

{
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
      extraCommands = ''
        iptables -A nixos-fw -s 10.211.55.0/24 -p tcp -m multiport --dports 22,80,443,6443 -j nixos-fw-accept
      '';
    };
  };

  systemd.network = {
    enable = true;
    networks = {
      "10-ethernet" = {
        matchConfig.Name = "en*";
        networkConfig = {
          Address = "${hostAddress}/24";
          Gateway = "10.211.55.1";
          DNS = [ "10.211.55.1" ];
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
}
