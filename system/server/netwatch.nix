{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.faragao-netwatch;
  netwatchPkg = pkgs.callPackage ../../pkgs/netwatch.nix { };
  netwatchCtl = pkgs.writeShellScriptBin "netwatch-ctl" ''
    exec /run/current-system/sw/bin/systemd-run --wait --pipe --collect -q \
      -p User=netwatch \
      -p Group=netwatch \
      -p StateDirectory=netwatch \
      -p LoadCredential="netwatch_env:${config.sops.secrets."netwatch_env".path}" \
      -E NETWATCH_STATE_FILE=/var/lib/netwatch/state.json \
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
      ];
      description = "Source CIDRs permitted for expected OPNsense admin logins.";
    };

    wanInterface = lib.mkOption {
      type = lib.types.str;
      default = "igc1";
      description = "OPNsense physical WAN interface name.";
    };

    allowedIngestCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.100.2/32" ];
      description = "Source CIDRs permitted to reach netwatch ingest and syslog ports via nixos-fw.";
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
        NETWATCH_STATE_FILE = "/var/lib/netwatch/state.json";
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

    networking.firewall.extraCommands = lib.concatMapStringsSep "\n" (cidr: ''
      iptables -w -A nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.port} -j nixos-fw-accept
      iptables -w -A nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.syslogPort} -j nixos-fw-accept
    '') cfg.allowedIngestCIDRs;

    networking.firewall.extraStopCommands = lib.concatMapStringsSep "\n" (cidr: ''
      iptables -w -D nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.port} -j nixos-fw-accept 2>/dev/null || true
      iptables -w -D nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.syslogPort} -j nixos-fw-accept 2>/dev/null || true
    '') cfg.allowedIngestCIDRs;
  };
}
