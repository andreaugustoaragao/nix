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
    nameservers = [ "192.168.100.2" ];
    clientNetworks = [
      "172.30.75.1/32"
      "192.168.10.0/24"
    ];
  };

  services.k3s.extraFlags = lib.mkAfter [
    "--tls-san=192.168.10.75"
    "--tls-san=workstation"
    "--tls-san=workstation.local"
  ];
  systemd.services.k3s.unitConfig.RequiresMountsFor = [ "/var/lib/rancher" ];
  services.dockerRegistry.storagePath = lib.mkForce "/var/lib/rancher/.registry";
  systemd.tmpfiles.rules = [
    "d /var/lib/rancher/.registry 0750 docker-registry docker-registry -"
  ];
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
