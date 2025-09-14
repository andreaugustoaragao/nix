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

  config = {
    # Set hostname and state version from metadata
    networking.hostName = hostName;
    system.stateVersion = stateVersion;
    
    # Common configuration
    time.timeZone = "America/Denver";
    i18n.defaultLocale = "en_US.UTF-8";
  };

}
