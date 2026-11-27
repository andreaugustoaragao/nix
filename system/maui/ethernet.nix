{ lib, ... }:
{
  networking.hostName = "maui"; # Define your hostname.
  networking.networkmanager.enable = true;
  networking.networkmanager.dns = "none";
  networking.interfaces.enp2s0.ipv4.addresses = [
    {
      address = "192.168.40.3";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.168.40.1";
  networking.nameservers = [
    "192.168.100.2"
    "9.9.9.9"
  ];
  networking.enableIPv6 = false;
  networking.useDHCP = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
    445
  ];
  networking.firewall.allowedUDPPorts = [ ];

  boot.kernelModules = [ "tcp_bbr" ];
  boot.kernel.sysctl = {
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_wmem" = "4096 65536 16777216";
    "net.ipv4.tcp_fastopen" = 3;
  };
}
