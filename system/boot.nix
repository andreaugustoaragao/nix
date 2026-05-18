{
  inputs,
  pkgs,
  lib,
  isWorkstation,
  ...
}:

{
  boot = {
    loader = lib.mkMerge [
      # Default systemd-boot configuration for non-workstation machines
      (lib.mkIf (!isWorkstation) {
        systemd-boot.enable = true;
        systemd-boot.configurationLimit = 10;
        efi.canTouchEfiVariables = true;
      })

      # GRUB configuration for workstation
      (lib.mkIf isWorkstation {
        systemd-boot.enable = false;
        efi.canTouchEfiVariables = true;
        efi.efiSysMountPoint = "/boot";

        grub = {
          enable = true;
          efiSupport = true;
          efiInstallAsRemovable = false;
          devices = [ "nodev" ];
          useOSProber = true;
          backgroundColor = "#24273a";
          splashImage = ../hardware/workstation/grub-background.png;
          gfxmodeEfi = "2560x1440";
          gfxpayloadEfi = "keep";
          configurationLimit = 20;
          extraEntries = "";
        };
      })
    ];

    # Workstation runs the CachyOS-tuned -lto kernel (BORE scheduler,
    # Clang+ThinLTO, perf patchset). Consumed via xddxdd's overlay
    # (registered below) so the kernel build closure aligns with the
    # rest of the system's nixpkgs. The LTO build occasionally trips
    # an LLD ThinLTO debug-info offset bug under parallelism — it's
    # non-deterministic. If `nixos-rebuild` fails with
    # `ld.lld: error: ... :(.debug_str): offset is outside the
    # section`, just retry. Other hosts stay on stock
    # linuxPackages_latest for driver compat (laptop) and aarch64 (vm).
    kernelPackages =
      if isWorkstation then
        pkgs.cachyosKernels."linuxPackages-cachyos-latest-lto"
      else
        pkgs.linuxPackages_latest;

    plymouth.enable = false;

    consoleLogLevel = 3;
    initrd.verbose = false;
    kernelParams = [
      "quiet"
      "loglevel=3"
      "splash"
      # Removed "console=tty7" to keep LUKS password prompt visible on tty1
      "udev.log_priority=3"
      "rd.udev.log_level=3"
      "systemd.show_status=auto"
      "vt.global_cursor_default=0"
      "logo.nologo"
    ];

    tmp = {
      useTmpfs = true;
      cleanOnBoot = true;
    };
  };

  # Register xddxdd's overlay (exposes pkgs.cachyosKernels.*) and
  # Lantian's attic cache. The cache holds the cachyos build
  # dependencies (LLVM, patched source, ~50 MiB of toolchain) but not
  # the final kernel — that compiles locally on first rebuild.
  nixpkgs.overlays = lib.mkIf isWorkstation [
    inputs.cachyos-kernel.overlays.default
  ];

  nix.settings = lib.mkIf isWorkstation {
    substituters = [ "https://attic.xuyh0120.win/lantian" ];
    trusted-public-keys = [ "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=" ];
  };
}
