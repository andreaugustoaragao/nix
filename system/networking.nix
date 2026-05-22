{
  pkgs,
  lib,
  wirelessInterface,
  hostName,
  isVm,
  isServer,
  ...
}:

{
  # Install wpa_gui when wireless is enabled
  environment.systemPackages = lib.mkIf (wirelessInterface != null) [
    pkgs.wpa_supplicant_gui
  ];
  systemd = {
    network = {
      # hostname is now set in system/default.nix from metadata
      enable = true;
      networks = {
        "10-ethernet" = {
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
                  "192.168.40.3"
                  "192.168.100.2"
                ];
                IPv6AcceptRA = true;
              }
            else if hostName == "tala" then
              {
                Address = "192.168.40.10/24";
                Gateway = "192.168.40.1";
                DNS = [
                  "192.168.40.3"
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
          dhcpV4Config = lib.mkIf (hostName == "hp-laptop") {
            RouteMetric = 1024;
          };
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
        "01-veth-ignore" = {
          matchConfig.Name = "veth*";
          linkConfig.Unmanaged = true;
        };
      };
    };
  };

  networking = {
    useNetworkd = true;
    useDHCP = false;

    # Conditional wireless configuration
    wireless = lib.mkIf (wirelessInterface != null) {
      enable = true;
      interfaces = [ wirelessInterface ];
      userControlled.enable = true; # Allow user-space configuration

      # Networks configured via SOPS secrets
      networks = {
        # Home network - using SOPS secret
        "FARAGAO" = {
          pskRaw = "ext:wifi_password_home";
          priority = 10;
        };

        # Work network - using SOPS secret
        "FARAGAO_WORK" = {
          pskRaw = "ext:wifi_password_work";
          priority = 1;
        };
      };

      # Secrets file containing SOPS secrets for wpa_supplicant
      secretsFile = "/run/secrets/wifi_env";
    };
  };

  # Wireless network configuration for systemd-networkd
  systemd.network.networks."20-wireless" = lib.mkIf (wirelessInterface != null) {
    matchConfig.Name = wirelessInterface;
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
    # On workstation only: don't accept DHCP/RA-supplied DNS on wifi.
    # resolved's Global DNS (192.168.40.3) plus the ethernet per-link list
    # already covers DNS, and adding the wifi router's resolver pushes the
    # unioned nameserver count past 3, triggering kubelet's
    # DNSConfigForming warning on every K3s pod sync (resolv.conf hard
    # cap is 3 nameservers). hp-laptop still needs wifi DHCP DNS — it has
    # no per-link DNS or Global resolved DNS and roams across networks.
    dhcpV4Config = {
      RouteMetric = 2048; # Higher metric than ethernet (prefers ethernet when both available)
      UseDNS = lib.mkIf (hostName == "workstation") false;
    };
    ipv6AcceptRAConfig = {
      RouteMetric = 2048;
      UseDNS = lib.mkIf (hostName == "workstation") false;
    };
  };

  # Disable network-wait-online for faster boot
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;

  # ============================================================================
  # DNS resolver — global config on systemd-resolved
  # ============================================================================
  # The per-link DNS configured on the "10-ethernet" network only kicks
  # in when that link is marked DefaultRoute=yes. With multiple en*
  # interfaces (enp11s0 down, enp5s0f0 carrying the actual route),
  # resolved sometimes lists the DNS on the wrong link, falls through
  # to the global fallback list (Quad9/Cloudflare/Google), and queries
  # never hit 192.168.40.3. Setting Global DNS on resolved sidesteps
  # link-routing entirely — every lookup goes through 192.168.40.3
  # first regardless of which link won the network match.
  services.resolved = {
    enable = true;
    extraConfig = lib.mkIf (hostName == "workstation") ''
      DNS=192.168.40.3
      FallbackDNS=1.1.1.1
      Domains=faragao.net
      MulticastDNS=no
    '';
  };

  # FQDN: hostname --fqdn → workstation.faragao.net.
  networking.domain = lib.mkIf (hostName == "workstation") "faragao.net";

  # Enable NTP time synchronization via systemd-timesyncd
  # mkForce needed to override parallels-guest.nix which disables it for VMs
  services.timesyncd.enable = lib.mkForce true;

  # ============================================================================
  # Kernel tuning — larger UDP buffers for QUIC (cloudflared, etc.)
  # ============================================================================
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 7500000;
    "net.core.wmem_max" = 7500000;

    # BBR + fq pacing — better throughput/latency over WAN, neutral on LAN.
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";

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
    127.0.1.1      workstation.faragao.net workstation
  '';

  # Keep explicit /etc/hosts entries authoritative for local dev domains.
  # Without this, .local names stall on the mDNS lookup — avahi returns
  # NOTFOUND for hostnames it doesn't actively advertise (fulcrum.local,
  # infinity.local, grafana.local, …) and the default
  # `mdns4_minimal [NOTFOUND=return]` short-circuits the chain before
  # `files` (= /etc/hosts) is ever consulted.
  system.nssDatabases.hosts =
    lib.mkIf (hostName == "workstation" || hostName == "prl-dev-vm" || hostName == "vmw-dev-vm")
      (
        lib.mkForce [
          "files"
          "mymachines"
          "mdns4_minimal [NOTFOUND=return]"
          "resolve [!UNAVAIL=return]"
          "myhostname"
          "dns"
          "mdns4"
        ]
      );

  networking.hosts."127.0.0.1" =
    lib.optionals (hostName != "workstation") [
      "grafana.local"
      "loki.local"
      "prometheus.local"
    ]
    ++ lib.optionals (hostName == "prl-dev-vm" || hostName == "vmw-dev-vm") [
      "fulcrum.local"
      "infinity.local"
    ]
    ++ lib.optionals (hostName == "workstation") [ "llm.local" ];

  # `mac-work` alias for the Apple Silicon laptop hosting these VMs.
  # The Mac's scutil names are pinned to IT's asset tag (G7CH2W2XYR),
  # so its Bonjour publishes `G7CH2W2XYR.local`, not `mac-work.local`.
  # Statically alias `mac-work` (and `mac-work.local`) to the
  # hypervisor's host-stub IP so existing service URLs keep working:
  #   prl-dev-vm  → 10.211.55.2  (bridge100, Parallels Shared; matches
  #                                whisper/local-llm bindHost)
  #   vmw-dev-vm  → 192.168.150.1 (vmnet8 host IP, from
  #                                /Library/Preferences/VMware Fusion/
  #                                vmnet8/nat.conf)
  networking.hosts."10.211.55.2" = lib.mkIf (hostName == "prl-dev-vm") [
    "mac-work"
    "mac-work.local"
  ];
  networking.hosts."192.168.150.1" = lib.mkIf (hostName == "vmw-dev-vm") [
    "mac-work"
    "mac-work.local"
  ];

  # ============================================================================
  # Firewall Configuration
  # ============================================================================
  networking.firewall = {
    enable = true;

    # Allowed TCP ports
    allowedTCPPorts = [
      22 # SSH
      6443 # K3s API server (required for pod-to-API-server traffic after kube-proxy DNAT)
    ]
    ++ lib.optionals (hostName == "workstation") [
      80 # K3s ingress (istio-ingress via klipper-lb)
      443
    ]
    ++ lib.optionals (hostName == "prl-dev-vm" || hostName == "vmw-dev-vm") [
      # Fulcrum HTTPS — source-run unit binds to 0.0.0.0:3100 so the
      # Parallels/VMware host (mac-work) can reach it at
      # https://<hostname>.local:3100.
      3100
    ]
    ++ lib.optionals isServer [
      80 # Caddy (ACME HTTP-01 fallback / redirect to 443)
      443 # Caddy reverse proxy for auth.faragao.net + lldap.faragao.net
      3890 # LLDAP — exposed on LAN so other hosts can bind clients
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
      "docker0" # Docker bridge
      "cni0" # K3s CNI bridge
      "flannel.1" # K3s Flannel
    ];

    # Log refused packets (useful for debugging)
    logRefusedConnections = true;
    logRefusedPackets = false; # Set to true only for debugging (can be noisy)

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
