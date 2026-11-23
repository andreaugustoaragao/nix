{
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
  ];

  boot = {
    initrd = {
      availableKernelModules = [
        "nvme"
        "nvme_core"
        "gve"
        "virtio_pci"
        "virtio_scsi"
        "virtio_blk"
        "xhci_pci"
        "sd_mod"
      ];
      kernelModules = [ ];
    };
    loader = {
      systemd-boot.enable = true;
      # GCE ARM64 UEFI boots via \EFI\BOOT\BOOTAA64.EFI and does not rely on
      # custom NVRAM variables surviving stop/start cycles.
      efi.canTouchEfiVariables = false;
    };
  };

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
