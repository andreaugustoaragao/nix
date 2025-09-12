{ config, pkgs, lib, inputs, ... }:

{
  networking.hostName = "parallels-nixos";
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

  # Disable network-wait-online for faster boot
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
} 