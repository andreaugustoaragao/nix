{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.faragao-netwatch;
  netwatchPkg = pkgs.callPackage ../../pkgs/netwatch.nix { };
  fleetPostureFile = pkgs.writeText "fleet-posture.json" (
    builtins.toJSON {
      devices = [
        {
          device = "chief-tui-opn";
          role = "primary-firewall";
          vendor = "OPNsense";
          product = "OPNsense Community Edition";
          update_channel = "26.7";
          cadence = "manual / daily audit";
          auto_update = false;
          last_verified_at = "2026-11-27T00:00:00Z";
          review_interval_days = 14;
          advisory_url = "https://forum.opnsense.org/index.php?board=11.0";
          notes = "Live inventory via opn-audit-export + pkg audit + KEV + Core/Plugins GHSA";
        }
        {
          device = "maui";
          role = "services-hub";
          vendor = "NixOS";
          product = "NixOS 26.11 (Zokor) + Grafana 13.3.1 / Vaultwarden / Continuwuity";
          running_version = "26.11.20261127.3068c73";
          version_source = "verified_inventory";
          update_channel = "nixos-26.11";
          cadence = "Sun 03:00 switch (no auto-reboot)";
          auto_update = true;
          last_verified_at = "2026-11-27T00:00:00Z";
          review_interval_days = 30;
          notes = "DEF-04 resolved on nixos-26.11; overridden live by maui-fleet-versions";
        }
        {
          device = "tala";
          role = "security-host";
          vendor = "NixOS";
          product = "NixOS 26.05 (Yarara)";
          update_channel = "nixos-26.05";
          cadence = "Sun 03:00 switch (no auto-reboot)";
          auto_update = true;
          last_verified_at = "2026-11-27T00:00:00Z";
          review_interval_days = 30;
          notes = "Live version read from local /etc/os-release + nixos-upgrade.service";
        }
        {
          device = "workstation";
          role = "admin-workstation";
          vendor = "NixOS";
          product = "NixOS 26.05 (Yarara)";
          running_version = "26.05.20261122.0dc498b";
          kernel_version = "7.2.9";
          version_source = "verified_inventory";
          update_channel = "nixos-26.05";
          cadence = "manual interactive rebuild";
          auto_update = false;
          last_verified_at = "2026-11-27T00:00:00Z";
          review_interval_days = 30;
          notes = "Intentionally excluded from auto-upgrade and unscraped across Work/Servers boundary";
        }
        {
          device = "chief-tui";
          role = "cold-standby";
          vendor = "Ubiquiti";
          product = "EdgeRouter 6P (EdgeOS)";
          running_version = "EdgeOS v3.0.1 (5862409.250924.1408)";
          version_source = "verified_inventory";
          update_channel = "v3.x";
          cadence = "manual / KEV + 30d review";
          auto_update = false;
          last_verified_at = "2026-11-27T00:00:00Z";
          review_interval_days = 30;
          advisory_url = "https://community.ui.com/releases";
          notes = "Standby WAN offline; matched against CISA KEV EdgeOS/EdgeRouter feeds";
        }
        {
          device = "tamatoa";
          role = "core-switch";
          vendor = "Brocade";
          product = "ICX6450-48 (FastIron Router)";
          running_version = "08.0.30uT313";
          version_source = "verified_inventory";
          update_channel = "08.0.30u";
          cadence = "EoL mitigated / KEV + 90d review";
          auto_update = false;
          last_verified_at = "2026-11-27T00:00:00Z";
          review_interval_days = 90;
          eol_status = "EoL mitigated by mgmt_access + ACL 91 + SSH-only";
          advisory_url = "https://support.ruckuswireless.com/security";
          notes = "Live sysDescr pushed via maui SNMPv3; compensating VLAN/ACL isolation in place";
        }
        {
          device = "ruckus-basement";
          role = "ap-member";
          vendor = "Ruckus";
          product = "Unleashed R550";
          running_version = "200.19.7.112.291";
          version_source = "verified_inventory";
          update_channel = "200.19";
          cadence = "manual / KEV + 30d review";
          auto_update = false;
          last_verified_at = "2026-11-27T00:00:00Z";
          review_interval_days = 30;
          advisory_url = "https://support.ruckuswireless.com/security";
          notes = "SNMPv3 off (owner-accepted RO-without-RW limitation); monitored via Blackbox + tamatoa 1/1/13";
        }
        {
          device = "ruckus-secondfloor";
          role = "ap-master";
          vendor = "Ruckus";
          product = "Unleashed R550";
          running_version = "200.19.7.112.291";
          version_source = "verified_inventory";
          update_channel = "200.19";
          cadence = "manual / KEV + 30d review";
          auto_update = false;
          last_verified_at = "2026-11-27T00:00:00Z";
          review_interval_days = 30;
          advisory_url = "https://support.ruckuswireless.com/security";
          notes = "SNMPv3 off (owner-accepted RO-without-RW limitation); monitored via HTTPS/Blackbox + tamatoa 1/1/14";
        }
        {
          device = "teka";
          role = "nas";
          vendor = "Synology";
          product = "DS218+";
          running_version = "DSM 7.3.2-86009 Update 6";
          version_source = "verified_inventory";
          update_channel = "DSM 7.3 LTS";
          cadence = "manual / KEV + 14d review";
          auto_update = false;
          last_verified_at = "2026-11-27T00:00:00Z";
          review_interval_days = 14;
          advisory_url = "https://www.synology.com/en-global/support/security/advisory";
          notes = "Upgraded 7.1.1-42962 Update 9 -> DSM 7.3.2-86009 Update 6 in TRK-33; live synoDSMVersion/synoUpgradeAvailable pushed from maui SNMPv3";
        }
        {
          device = "authentik";
          role = "identity-provider";
          vendor = "Authentik";
          product = "Authentik OCI (tala)";
          running_version = config.services.faragao-authentik.version;
          version_source = "declared_oci_pin";
          update_channel = "ghcr.io/goauthentik/server";
          cadence = "pinned OCI tag + GitHub Release/GHSA/KEV";
          auto_update = false;
          last_verified_at = "2026-11-27T00:00:00Z";
          review_interval_days = 14;
          advisory_url = "https://github.com/goauthentik/authentik/security/advisories";
          notes = "Pinned ghcr.io/goauthentik/server OCI on tala; tracked against goauthentik/authentik releases, GHSAs, and CISA KEV";
        }
      ];
    }
  );
  netwatchCtl = pkgs.writeShellScriptBin "netwatch-ctl" ''
    exec /run/current-system/sw/bin/systemd-run --wait --pipe --collect -q \
      -p User=netwatch \
      -p Group=netwatch \
      -p StateDirectory=netwatch \
      -p LoadCredential="netwatch_env:${config.sops.secrets."netwatch_env".path}" \
      -E NETWATCH_STATE_FILE=/var/lib/netwatch/state.json \
      -E NETWATCH_FLEET_FILE=${fleetPostureFile} \
      ${lib.getExe netwatchPkg} "$@"
  '';
in
{
  options.services.faragao-netwatch = {
    enable = lib.mkEnableOption "faragao.net security monitoring and firewall advisory daemon";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Listen address for OPNsense read-only audit ingestion.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9400;
      description = "TCP listen port for firewall push ingestion.";
    };

    syslogPort = lib.mkOption {
      type = lib.types.port;
      default = 5514;
      description = "Private TCP listen port for OPNsense RFC 5424 remote syslog forwarding.";
    };

    syslogStaleAfter = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "Duration after which silence on remote syslog raises a distinct telemetry fault.";
    };

    allowedAdminUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "andre" ];
      description = "OPNsense admin usernames considered normal.";
    };

    allowedAdminSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "192.168.10.75/32"
        "192.168.50.0/24"
        "192.168.60.0/24"
      ];
      description = "Source CIDRs permitted for expected OPNsense admin logins.";
    };

    wanInterface = lib.mkOption {
      type = lib.types.str;
      default = "igc1";
      description = "OPNsense physical WAN interface name.";
    };

    allowedWANPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [
        443
        51820
      ];
      description = "Expected WAN inbound destination ports (excluded from unexpected WAN-pass alerts).";
    };

    allowedIngestCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.100.2/32" ];
      description = "Source CIDRs permitted to reach netwatch ingest and syslog ports via nixos-fw.";
    };

    allowedMetricsCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.40.3/32" ];
      description = "Source CIDRs permitted to scrape netwatch /metrics (port 9400 only; no syslog access).";
    };

    dailyHour = lib.mkOption {
      type = lib.types.ints.between 0 23;
      default = 8;
      description = "Local hour (0-23) for grouped daily security action email.";
    };

    digestWeekday = lib.mkOption {
      type = lib.types.str;
      default = "Sunday";
      description = "Weekday for routine updates and freshness weekly digest.";
    };

    digestHour = lib.mkOption {
      type = lib.types.ints.between 0 23;
      default = 9;
      description = "Local hour (0-23) for weekly digest email.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      netwatchPkg
      netwatchCtl
    ];

    sops.secrets."netwatch_env" = {
      sopsFile = ../../secrets/tala.yaml;
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "netwatch.service" ];
    };

    users.users.netwatch = {
      isSystemUser = true;
      group = "netwatch";
      description = "faragao.net security monitoring daemon";
    };
    users.groups.netwatch = { };

    systemd.services.netwatch = {
      description = "faragao.net Firewall Advisory, Notification, and Heartbeat Daemon";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        NETWATCH_LISTEN_ADDR = "${cfg.listenAddress}:${toString cfg.port}";
        NETWATCH_SYSLOG_ADDR = "${cfg.listenAddress}:${toString cfg.syslogPort}";
        NETWATCH_SYSLOG_STALE_AFTER = cfg.syslogStaleAfter;
        NETWATCH_SYSLOG_ALLOWED_IPS = "192.168.100.2,127.0.0.1,::1";
        NETWATCH_ADMIN_USERS = lib.concatStringsSep "," cfg.allowedAdminUsers;
        NETWATCH_ADMIN_SOURCES = lib.concatStringsSep "," cfg.allowedAdminSources;
        NETWATCH_WAN_IFACE = cfg.wanInterface;
        NETWATCH_ALLOWED_WAN_PORTS = lib.concatStringsSep "," (map toString cfg.allowedWANPorts);
        NETWATCH_STATE_FILE = "/var/lib/netwatch/state.json";
        NETWATCH_FLEET_FILE = "${fleetPostureFile}";
        NETWATCH_DAILY_HOUR = toString cfg.dailyHour;
        NETWATCH_DIGEST_WEEKDAY = cfg.digestWeekday;
        NETWATCH_DIGEST_HOUR = toString cfg.digestHour;
      };

      serviceConfig = {
        Type = "simple";
        User = "netwatch";
        Group = "netwatch";
        ExecStart = "${lib.getExe netwatchPkg} serve";
        LoadCredential = "netwatch_env:${config.sops.secrets."netwatch_env".path}";
        StateDirectory = "netwatch";
        StateDirectoryMode = "0700";
        Restart = "on-failure";
        RestartSec = "10s";

        # Hardening boundaries
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };

    systemd.services."netwatch-unit-alert@" = {
      description = "Send direct SMTP alert when systemd unit %i fails on tala";
      serviceConfig = {
        Type = "oneshot";
        User = "netwatch";
        Group = "netwatch";
        SupplementaryGroups = [ "systemd-journal" ];
        LoadCredential = "netwatch_env:${config.sops.secrets."netwatch_env".path}";
        ExecStart = "${lib.getExe netwatchPkg} alert-unit --unit %i";
      };
    };

    systemd.services.nixos-upgrade = lib.mkIf config.system.autoUpgrade.enable {
      onFailure = lib.mkAfter [ "netwatch-unit-alert@nixos-upgrade.service" ];
    };

    networking.firewall.extraCommands =
      lib.concatMapStringsSep "\n" (cidr: ''
        iptables -w -A nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.port} -j nixos-fw-accept
        iptables -w -A nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.syslogPort} -j nixos-fw-accept
      '') cfg.allowedIngestCIDRs
      + "\n"
      + lib.concatMapStringsSep "\n" (cidr: ''
        iptables -w -A nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.port} -j nixos-fw-accept
      '') cfg.allowedMetricsCIDRs;

    networking.firewall.extraStopCommands =
      lib.concatMapStringsSep "\n" (cidr: ''
        iptables -w -D nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.port} -j nixos-fw-accept 2>/dev/null || true
        iptables -w -D nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.syslogPort} -j nixos-fw-accept 2>/dev/null || true
      '') cfg.allowedIngestCIDRs
      + "\n"
      + lib.concatMapStringsSep "\n" (cidr: ''
        iptables -w -D nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.port} -j nixos-fw-accept 2>/dev/null || true
      '') cfg.allowedMetricsCIDRs;
  };
}
