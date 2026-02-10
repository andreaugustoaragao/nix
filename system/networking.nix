{
  config,
  pkgs,
  lib,
  inputs,
  wirelessInterface,
  isVm,
  ...
}:

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

  # Enable NTP time synchronization via systemd-timesyncd (VMs sync from host)
  services.timesyncd.enable = lib.mkIf (!isVm) true;

  # ============================================================================
  # Firewall Configuration
  # ============================================================================
  networking.firewall = {
    enable = true;

    # Allowed TCP ports
    allowedTCPPorts = [
      22    # SSH
      # 6443  # K3s API server (uncomment if needed externally)
    ];

    # Allowed UDP ports
    allowedUDPPorts = [
      # Add any required UDP ports here
    ];

    # Allowed TCP port ranges
    allowedTCPPortRanges = [
      # { from = 30000; to = 32767; }  # K3s NodePorts (uncomment if needed)
    ];

    # Allowed UDP port ranges
    allowedUDPPortRanges = [
      # { from = 30000; to = 32767; }  # K3s NodePorts (uncomment if needed)
    ];

    # Trust local interfaces for Docker and K3s
    trustedInterfaces = [
      "docker0"     # Docker bridge
      "cni0"        # K3s CNI bridge
      "flannel.1"   # K3s Flannel
    ];

    # Log refused packets (useful for debugging)
    logRefusedConnections = true;
    logRefusedPackets = false;  # Set to true only for debugging (can be noisy)

    # Allow ping
    allowPing = true;

    # Extra firewall commands (if needed)
    extraCommands = ''
      # Allow established connections
      iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

      # Allow loopback
      iptables -A INPUT -i lo -j ACCEPT
    '';
  };
}

