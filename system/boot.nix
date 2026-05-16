{
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
