{
  config,
  pkgs,
  lib,
  inputs,
  isWorkstation,
  ...
}:

{
  boot.loader = lib.mkMerge [
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
        devices = ["nodev"];
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

  #boot.kernelPackages = pkgs.linuxPackages_zen;

  boot.plymouth.enable = false;

  boot.consoleLogLevel = 3;
  boot.initrd.verbose = false;
  boot.kernelParams = [
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

  boot.tmp.useTmpfs = true;
  boot.tmp.cleanOnBoot = true;
}
