{ hostName, hostAddress, ... }:

{
  services.k3s = {
    enable = true;
    role = "server";
    # Embedded etcd enables K3s' built-in snapshot/restore workflow.
    clusterInit = true;
    disable = [ "traefik" ]; # Existing workloads use Istio for ingress.
    extraFlags = [
      "--node-ip=${hostAddress}"
      "--tls-san=${hostAddress}"
      "--tls-san=${hostName}"
      "--tls-san=${hostName}.local"
      "--write-kubeconfig-mode=0640"
      "--write-kubeconfig-group=k3s-admin"
      "--secrets-encryption"
      "--etcd-snapshot-retention=14"
      "--etcd-snapshot-compress"
      "--resolv-conf=/run/systemd/resolve/resolv.conf"
      "--kubelet-arg=system-reserved=memory=2Gi"
    ];
  };
}
