{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.faragao-netwatch;
  netwatchPkg = pkgs.callPackage ../../pkgs/netwatch.nix { };
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

    allowedIngestCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.100.2/32" ];
      description = "Source CIDRs permitted to reach netwatch ingest port via nixos-fw.";
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
    environment.systemPackages = [ netwatchPkg ];

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

    networking.firewall.extraCommands = lib.concatMapStringsSep "\n" (
      cidr: "iptables -w -A nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.port} -j nixos-fw-accept"
    ) cfg.allowedIngestCIDRs;

    networking.firewall.extraStopCommands = lib.concatMapStringsSep "\n" (
      cidr:
      "iptables -w -D nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.port} -j nixos-fw-accept 2>/dev/null || true"
    ) cfg.allowedIngestCIDRs;
  };
}
