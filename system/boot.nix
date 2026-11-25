{
  config,
  inputs,
  pkgs,
  lib,
  isWorkstation,
  isLaptop,
  isVm,
  isServer,
  ...
}:

{
  imports = [ inputs.bootvine.nixosModules.default ];

  services.bootvine = {
    enable = lib.mkDefault (isWorkstation || isLaptop || (isVm && !isServer));
    settings = lib.mkIf config.services.bootvine.enable {
      colors = {
        tree.current-stage = "light-yellow";
        tree.running-marker = "light-yellow";
        timeline.running = "light-yellow";
        footer.running = "light-yellow";
        password.frame = "light-yellow";
      };
    };
  };

  # Use the sample VM's readable font in the boot console, including the initrd.
  console = lib.mkIf config.services.bootvine.enable {
    earlySetup = lib.mkDefault true;
    font = lib.mkDefault "${pkgs.terminus_font}/share/consolefonts/ter-v20n.psf.gz";
  };

  boot = {
    loader = lib.mkMerge [
      # Default systemd-boot configuration for non-workstation machines
      (lib.mkIf (!isWorkstation) {
        timeout = lib.mkDefault 1;
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

    # Stock linuxPackages_latest across all hosts. Workstation previously ran
    # the CachyOS-tuned -lto kernel for BORE/Clang+ThinLTO/perf patches, but
    # both cachyos-latest-lto and cachyos-lts-lto wedge MT7925 Bluetooth — the
    # btmtk WMT firmware handshake times out on probe and on rebind. Stock
    # mainline has the working driver. Revisit cachy once the regression is
    # resolved upstream.
    kernelPackages = pkgs.linuxPackages_latest;

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
    substituters = [ "https://cache.lantian.pub/lantian" ];
    trusted-public-keys = [ "lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ=" ];
  };
}
