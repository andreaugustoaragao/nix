# Parallels on Apple Silicon. Label/subvolume layout matches install-nixos.sh.
# The VM owns its virtual disk; no host shared folders are mounted.
{ lib, ... }:

let
  btrfsMount = subvolume: {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = [
      "subvol=${subvolume}"
      "compress=zstd:1"
      "noatime"
      "discard=async"
    ];
  };
in
{
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  boot = {
    initrd.availableKernelModules = [
      "xhci_pci"
      "usbhid"
      "sr_mod"
      "sd_mod"
      "ahci"
      "nvme"
      "virtio_pci"
      "virtio_mmio"
      "virtio_blk"
      "virtio_scsi"
      "virtio_net"
    ];
    kernelModules = [
      "virtio_balloon"
      "br_netfilter"
      "overlay"
    ];
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    supportedFilesystems = [ "btrfs" ];
  };

  fileSystems = {
    "/" = btrfsMount "@root";
    "/home/aragao" = btrfsMount "@home-aragao";
    "/nix" = btrfsMount "@nix";
    "/tmp" = btrfsMount "@tmp";
    "/.snapshots" = btrfsMount "@snapshots";
    "/boot" = {
      device = "/dev/disk/by-label/nixos-boot";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };
  };

  # Kubelet uses the default failSwapOn=true; provision sufficient VM RAM.
  swapDevices = [ ];

  # prl-tools automatically mounts Mac shares. A headless cluster only
  # needs the kernel's virtual hardware drivers and network time sync.
  hardware.parallels.enable = false;
}
