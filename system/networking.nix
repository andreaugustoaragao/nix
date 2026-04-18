{
  config,
  pkgs,
  lib,
  inputs,
  wirelessInterface,
  hostName,
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
    networkConfig =
      if hostName == "prl-dev-vm" then
        {
          Address = "10.211.55.4/24";
          Gateway = "10.211.55.1";
          DNS = [
            "10.211.55.1"
            "1.1.1.1"
            "8.8.8.8"
          ];
          IPv6AcceptRA = true;
        }
      else if hostName == "workstation" then
        {
          Address = "192.168.10.75/24";
          Gateway = "192.168.10.1";
          DNS = [
            "192.168.10.1"
            "1.1.1.1"
            "8.8.8.8"
          ];
          IPv6AcceptRA = true;
        }
      else
        {
          DHCP = "yes";
          IPv6AcceptRA = true;
        };
    dhcpV4Config = lib.mkIf (hostName == "hp-laptop") (
      {
        RouteMetric = 1024;
      }
    );
    dns = lib.mkIf (isVm && hostName != "prl-dev-vm") [
      "1.1.1.1#cloudflare-dns.com"
      "8.8.8.8#dns.google"
    ];
    ipv6AcceptRAConfig = {
      RouteMetric = 1024;
    };
  };

  # Tell networkd to ignore container/K3s veth interfaces — their constant
  # creation/destruction floods the journal with carrier-change noise.
  systemd.network.networks."01-veth-ignore" = {
    matchConfig.Name = "veth*";
    linkConfig.Unmanaged = true;
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

  # Enable NTP time synchronization via systemd-timesyncd
  # mkForce needed to override parallels-guest.nix which disables it for VMs
  services.timesyncd.enable = lib.mkForce true;

  # ============================================================================
  # Kernel tuning — larger UDP buffers for QUIC (cloudflared, etc.)
  # ============================================================================
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 7500000;
    "net.core.wmem_max" = 7500000;

    # Prevent new interfaces (K3s/Docker veths) from auto-generating IPv6
    # link-local addresses. The constant address churn triggers Chrome's
    # netlink watcher → ERR_NETWORK_CHANGED on every pod lifecycle event.
    "net.ipv6.conf.default.disable_ipv6" = 1;

    # -------------------------
    # Dev / load-testing tuning
    # -------------------------
    # Widen ephemeral port range (~64K ports instead of ~28K)
    "net.ipv4.ip_local_port_range" = "1024 65535";
    # Free TIME_WAIT sockets faster (15s instead of 60s)
    "net.ipv4.tcp_fin_timeout" = 15;
    # Reuse TIME_WAIT sockets for outgoing connections
    "net.ipv4.tcp_tw_reuse" = 1;
    # Keep congestion window between bursts (avoids ramp-up penalty)
    "net.ipv4.tcp_slow_start_after_idle" = 0;
    # TFO for both client and server (useful for local test servers)
    "net.ipv4.tcp_fastopen" = 3;
    # Detect dead connections faster (5min instead of 2h)
    "net.ipv4.tcp_keepalive_time" = 300;
  };

  # ============================================================================
  # Local DNS — friendly names for reverse-proxied services
  # ============================================================================
  networking.extraHosts = lib.mkIf (hostName == "workstation") ''
    192.168.10.75  infinity.local
  '';

  networking.hosts."127.0.0.1" =
    [
      "grafana.local"
      "loki.local"
      "prometheus.local"
    ]
    ++ lib.optionals (hostName == "prl-dev-vm") [ "fulcrum.local" "infinity.local" ]
    ++ lib.optionals (!isVm) [ "ollama.local" ];

  # ============================================================================
  # Firewall Configuration
  # ============================================================================
  networking.firewall = {
    enable = true;

    # Allowed TCP ports
    allowedTCPPorts = [
      22    # SSH
      6443  # K3s API server (required for pod-to-API-server traffic after kube-proxy DNAT)
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

