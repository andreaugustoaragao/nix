{ config, pkgs, lib, inputs, wirelessInterface, ... }:

{
  # Install wpa_gui when wireless is enabled
  environment.systemPackages = lib.mkIf (wirelessInterface != null) [
    pkgs.wpa_supplicant_gui
  ];
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
    
    # Networks configured via SOPS secrets
    networks = {
      # Home network - using SOPS secret
      "FARAGAO" = {
        pskRaw = "ext:wifi_password_home";
      };
      
      # Work network - using SOPS secret  
      "FARAGAO_WORK" = {
        pskRaw = "ext:wifi_password_work";
      };
    };
    
    # Secrets file containing SOPS secrets for wpa_supplicant
    secretsFile = "/run/secrets/wifi_env";
  };

  # Wireless network configuration for systemd-networkd
  systemd.network.networks."20-wireless" = lib.mkIf (wirelessInterface != null) {
    # matchConfig.Name = wirelessInterface;
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