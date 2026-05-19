# Hand-written (not nixos-generate-config output) — the disk layout is
# fully label-addressed so this file is reusable across rebuilds of the
# same VM. Mirrors hardware/prl-dev-vm/hardware-configuration.nix, but
# targets VMware Fusion on Apple Silicon.
#
# On aarch64 Fusion the guest is virtio-shaped, NOT vmw_*-shaped: the
# upstream Linux vmw_balloon / vmw_vmci / vmw_pvscsi drivers are x86-
# only (they fail to build on aarch64 with the CachyOS kernel — that's
# how this file got rewritten). Fusion on Apple Silicon presents:
#   * disk     — NVMe (/dev/nvme0n1)
#   * NIC      — virtio-net
#   * balloon  — virtio_balloon
#   * gpu      — virtio_gpu
# so initrd just needs nvme + virtio. open-vm-tools comes from
# virtualisation.vmware.guest at the bottom of this file and runs in
# userspace — no kernel module dependency on its side.
{
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot = {
    initrd = {
      availableKernelModules = [
        # Disk on Apple Silicon Fusion is NVMe
        "nvme"
        # virtio devices (net, balloon, etc. — Fusion uses these on aarch64)
        "virtio_net"
        "virtio_pci"
        "virtio_mmio"
        "virtio_blk"
        "virtio_balloon"
        # USB + optical (for installer ISO; harmless post-install)
        "xhci_pci"
        "ehci_pci"
        "usbhid"
        "sr_mod"
        "sd_mod"
      ];
      kernelModules = [ ];
    };
    kernelModules = [ ];
    extraModulePackages = [ ];

    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    supportedFilesystems = [ "btrfs" ];
  };

  # Same label-addressed btrfs layout the install script produces.
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = [
        "subvol=@root"
        "compress=zstd:1"
        "noatime"
        "space_cache=v2"
        "discard=async"
      ];
    };

    "/home/aragao" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = [
        "subvol=@home-aragao"
        "compress=zstd:1"
        "noatime"
        "space_cache=v2"
        "discard=async"
      ];
    };

    "/nix" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = [
        "subvol=@nix"
        "compress=zstd:1"
        "noatime"
        "space_cache=v2"
        "discard=async"
      ];
    };

    "/tmp" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = [
        "subvol=@tmp"
        "compress=zstd:1"
        "noatime"
        "space_cache=v2"
        "discard=async"
      ];
    };

    "/.snapshots" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = [
        "subvol=@snapshots"
        "compress=zstd:1"
        "noatime"
        "space_cache=v2"
        "discard=async"
      ];
    };

    "/boot" = {
      device = "/dev/disk/by-label/nixos-boot";
      fsType = "vfat";
    };

    "/swap" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "btrfs";
      options = [
        "subvol=@swap"
        "compress=zstd:1"
        "noatime"
        "space_cache=v2"
        "discard=async"
      ];
    };
  };

  swapDevices = [
    {
      device = "/swap/swapfile";
      size = 16384;
    }
  ];

  # VMware Fusion NAT DNS can be flaky, just like Parallels — leave VM
  # on DHCP and let system/networking.nix override DNS to 1.1.1.1/8.8.8.8
  # (the isVm && hostName != "prl-dev-vm" branch covers us).
  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # open-vm-tools (clipboard, screen resize, time sync, guest info).
  # No unfree predicate needed — unlike prl-tools, this is FOSS.
  virtualisation.vmware.guest.enable = true;
}
