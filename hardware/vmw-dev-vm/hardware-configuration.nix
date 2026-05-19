# Hand-written (not nixos-generate-config output) — the disk layout is
# fully label-addressed so this file is reusable across rebuilds of the
# same VM. Mirrors hardware/prl-dev-vm/hardware-configuration.nix, but
# swaps the Parallels guest agent for VMware Fusion's:
#   * vmw_pvscsi  — paravirtual SCSI controller (VMware's virtio-blk)
#   * vmxnet3     — paravirtual NIC
#   * vmw_balloon — memory balloon driver
#   * vmw_vmci    — VM communication interface (used by open-vm-tools)
#   * nvme + virtio_* — fallbacks; Fusion on Apple Silicon sometimes
#     surfaces the disk as NVMe and the NIC as virtio-net depending on
#     the VM hardware version. Loading the modules is cheap; the kernel
#     only binds the ones that match present devices.
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
        # VMware paravirtual
        "vmw_pvscsi"
        "vmxnet3"
        "vmw_balloon"
        "vmw_vmci"
        # Generic fallbacks (NVMe disk, virtio NIC/blk on aarch64 Fusion)
        "nvme"
        "virtio_net"
        "virtio_pci"
        "virtio_mmio"
        "virtio_blk"
        "virtio_balloon"
        # USB + optical for installer ISO
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
