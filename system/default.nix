{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./nix.nix
    ./packages.nix
    ./desktop.nix
    ./virtualization.nix
    ./audio.nix
    ./greetd.nix
    ./users.nix
    ./networking.nix
    ./ssh.nix
    ./kmscon.nix
    ./env.nix
    ./fonts.nix
    ./nvim.nix
  ];

  config.time.timeZone = "America/Denver";
  config.i18n.defaultLocale = "en_US.UTF-8";

  # Centralized DPI configuration
  options.machine.dpi = lib.mkOption {
    type = lib.types.int;
    default = 144;
    description = "Default DPI to be used system-wide for X11 and applications";
  };

  config = {
    system.stateVersion = "24.11";
  }; # All other system config moved under ./system

}
