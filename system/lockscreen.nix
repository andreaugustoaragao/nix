{ config, pkgs, lib, lockScreen ? false, ... }:

lib.mkIf lockScreen {
  # System-level PAM configuration for swaylock
  # Required on NixOS for swaylock to properly authenticate
  # Without this, swaylock shows black screen but doesn't actually lock
  security.pam.services.swaylock = {};
}