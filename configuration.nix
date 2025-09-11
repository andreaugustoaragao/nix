{ config, pkgs, lib, inputs, ... }:
#

{
  imports = [
    ./system
  ];

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
