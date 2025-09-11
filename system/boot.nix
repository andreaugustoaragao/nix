{ config, pkgs, lib, inputs, ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.plymouth = {
    enable = true;
    theme = "rings";
    themePackages = with pkgs; [
      (adi1090x-plymouth-themes.override { selected_themes = [ "rings" ]; })
    ];
  };

  boot.consoleLogLevel = 3;
  boot.initrd.verbose = false;

  boot.tmp.useTmpfs = false;
  boot.tmp.cleanOnBoot = true;
} 