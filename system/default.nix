{ config, pkgs, lib, inputs, ... }:

{
  imports = [
    ../hardware-configuration.nix
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

  time.timeZone = "America/Denver";
  i18n.defaultLocale = "en_US.UTF-8";
}
