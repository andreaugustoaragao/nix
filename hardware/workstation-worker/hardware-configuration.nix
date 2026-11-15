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
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  fileSystems."/home" = {
    device = "/dev/disk/by-label/worker-jobs";
    fsType = "ext4";
    options = [ "noatime" ];
  };
  swapDevices = [ ];
  system.build.workerImage = pkgs.callPackage (modulesPath + "/../lib/make-disk-image.nix") {
    inherit config;
    # Upstream cptofs hard-codes a 100 MiB embedded kernel, too small for this closure.
    pkgs = pkgs // {
      lkl = pkgs.callPackage ../../pkgs/lkl-cptofs.nix { };
    };
    name = "workstation-worker-image";
    format = "qcow2";
    partitionTableType = "legacy";
    diskSize = "auto";
    additionalSpace = "2G";
    copyChannel = false;
  };
}
