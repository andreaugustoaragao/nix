{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelPackages = pkgs.linuxPackages_zen;

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
