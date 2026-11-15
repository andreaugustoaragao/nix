{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  boot = {
    loader.grub = {
      enable = true;
      device = "/dev/vda";
    };
    loader.timeout = 1;
    growPartition = true;
    kernelParams = [ "console=ttyS0,115200" ];
    kernelModules = [
      "br_netfilter"
      "overlay"
    ];
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  fileSystems."/var/lib/rancher" = {
    device = "/dev/disk/by-label/k3s-data";
    fsType = "ext4";
    options = [ "noatime" ];
  };
  swapDevices = [ ];
  hardware.parallels.enable = false;

  my.kubernetes.network = {
    gateway = "172.30.75.1";
    prefixLength = 30;
    nameservers = [ "192.168.40.3" ];
    clientNetworks = [
      "172.30.75.1/32"
      "192.168.10.0/24"
    ];
  };

  # Keep the source cluster's SQLite format and local-volume node affinity.
  # Moving to etcd or enabling secrets encryption is a separate migration.
  services.k3s = {
    clusterInit = lib.mkForce false;
    extraFlags = lib.mkForce [
      "--node-name=workstation"
      "--node-ip=172.30.75.2"
      "--tls-san=172.30.75.2"
      "--tls-san=192.168.10.75"
      "--tls-san=workstation"
      "--tls-san=workstation.local"
      "--write-kubeconfig-mode=0640"
      "--write-kubeconfig-group=k3s-admin"
      "--resolv-conf=/run/systemd/resolve/resolv.conf"
      "--kubelet-arg=system-reserved=memory=2Gi"
    ];
  };
  # An empty preparation VM must never create or run a second cluster.
  systemd.services.k3s.unitConfig = {
    ConditionPathExists = "/var/lib/rancher/.migration/ready";
    RequiresMountsFor = [ "/var/lib/rancher" ];
  };
  services.dockerRegistry.storagePath = lib.mkForce "/var/lib/rancher/.registry";
  systemd.tmpfiles.rules = [
    "d /var/lib/rancher/.registry 0750 docker-registry docker-registry -"
  ];
  systemd.services.kubernetes-migration-identity = {
    description = "Restore the migrated cluster node identity";
    requiredBy = [
      "k3s.service"
      "docker-registry.service"
    ];
    before = [
      "k3s.service"
      "docker-registry.service"
    ];
    unitConfig = {
      ConditionPathExists = "/var/lib/rancher/.migration/ready";
      RequiresMountsFor = [ "/var/lib/rancher" ];
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      ${pkgs.coreutils}/bin/install -Dm600 /var/lib/rancher/.migration/node-password /etc/rancher/node/password
      ${pkgs.coreutils}/bin/chown -R docker-registry:docker-registry /var/lib/rancher/.registry
    '';
  };

  system.build.kubernetesImage = pkgs.callPackage (modulesPath + "/../lib/make-disk-image.nix") {
    inherit config;
    name = "workstation-k8s-vm-image";
    format = "qcow2";
    partitionTableType = "legacy";
    diskSize = "auto";
    additionalSpace = "2G";
    copyChannel = false;
  };
}
