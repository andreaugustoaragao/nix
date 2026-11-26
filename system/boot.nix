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

    # Stock mainline kernel across all hosts.
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
}
