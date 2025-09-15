{ config, pkgs, lib, inputs, wirelessInterface, ... }:

{
  # hostname is now set in system/default.nix from metadata
  systemd.network.enable = true;
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."10-ethernet" = {
    matchConfig.Name = "en*";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
    dhcpV4Config = {
      RouteMetric = 1024;
    };
    ipv6AcceptRAConfig = {
      RouteMetric = 1024;
    };
  };

  # Conditional wireless configuration
  networking.wireless = lib.mkIf (wirelessInterface != null) {
    enable = true;
    interfaces = [ wirelessInterface ];
    userControlled.enable = true; # Allow user-space configuration
    networks = {}; # Empty networks to prevent config file errors
    # Networks can be configured via wpa_supplicant_gui or manually
    # Example:
    # networks = {
    #   "MyWiFiNetwork" = {
    #     psk = "password";
    #   };
    # };
  };

  # Wireless network configuration for systemd-networkd
  systemd.network.networks."20-wireless" = lib.mkIf (wirelessInterface != null) {
    matchConfig.Name = wirelessInterface;
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
    dhcpV4Config = {
      RouteMetric = 2048; # Higher metric than ethernet (prefers ethernet when both available)
    };
    ipv6AcceptRAConfig = {
      RouteMetric = 2048;
    };
  };

  # Disable network-wait-online for faster boot
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
} 