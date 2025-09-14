{
  config,
  pkgs,
  lib,
  inputs,
  isWorkstation,
  isLaptop, 
  isVm,
  owner,
  hostName,
  stateVersion,
  profile,
  ...
}:

{
  imports = [
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
    ./sops.nix
  ];

  # Centralized DPI configuration
  options.machine.dpi = lib.mkOption {
    type = lib.types.int;
    default = 144;
    description = "Default DPI to be used system-wide for X11 and applications";
  };

  config = {
    # Set hostname and state version from metadata
    networking.hostName = hostName;
    system.stateVersion = stateVersion;
    
    # Common configuration
    time.timeZone = "America/Denver";
    i18n.defaultLocale = "en_US.UTF-8";
  };

}
