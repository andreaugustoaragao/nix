{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.faragao-authentik;
  dbInitScript = pkgs.writeShellApplication {
    name = "authentik-db-init";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      cfg.postgresPackage
    ];
    text = ''
      set -euo pipefail
      env_file="$CREDENTIALS_DIRECTORY/authentik_env"
      pg_pass=$(grep -E '^AUTHENTIK_POSTGRESQL__PASSWORD=' "$env_file" | head -n1 | cut -d= -f2-)
      if [ -z "$pg_pass" ]; then
        echo "missing AUTHENTIK_POSTGRESQL__PASSWORD in authentik_env" >&2
        exit 1
      fi
      escaped=$(printf '%s' "$pg_pass" | sed 's/\x27/\x27\x27/g')
      printf "ALTER ROLE authentik WITH LOGIN PASSWORD '%s';\n" "$escaped" \
        | psql -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null
    '';
  };
  commonEnv = {
    AUTHENTIK_POSTGRESQL__HOST = "127.0.0.1";
    AUTHENTIK_POSTGRESQL__PORT = "5432";
    AUTHENTIK_POSTGRESQL__USER = "authentik";
    AUTHENTIK_POSTGRESQL__NAME = "authentik";
    AUTHENTIK_ERROR_REPORTING__ENABLED = "false";
    AUTHENTIK_DISABLE_UPDATE_CHECK = "true";
    AUTHENTIK_DISABLE_STARTUP_ANALYTICS = "true";
  };
in
{
  options.services.faragao-authentik = {
    enable = lib.mkEnableOption "Authentik OCI identity broker on tala";

    version = lib.mkOption {
      type = lib.types.str;
      default = "2026.8.7";
      description = "Pinned Authentik OCI image version tag tracked by netwatch.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/goauthentik/server:${cfg.version}";
      description = "OCI container image for Authentik server and worker.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9000;
      description = "Internal HTTP port exposed only to approved reverse proxies.";
    };

    allowedProxyCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "192.168.40.3/32" ];
      description = "Source CIDRs permitted to reach Authentik HTTP over nixos-fw.";
    };

    postgresPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.postgresql_16;
      description = "PostgreSQL package backing Authentik on tala.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.backend = "docker";

    services.postgresql = {
      enable = true;
      package = cfg.postgresPackage;
      ensureDatabases = [ "authentik" ];
      ensureUsers = [
        {
          name = "authentik";
          ensureDBOwnership = true;
        }
      ];
      settings = {
        max_connections = 150;
      };
      authentication = lib.mkOverride 10 ''
        local all all peer
        host authentik authentik 127.0.0.1/32 scram-sha-256
        host authentik authentik ::1/128 scram-sha-256
      '';
    };

    sops.secrets."authentik_env" = {
      sopsFile = ../../secrets/tala.yaml;
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [
        "authentik-db-init.service"
        "docker-authentik-server.service"
        "docker-authentik-worker.service"
      ];
    };

    sops.secrets."authentik_google_oauth_env" = {
      sopsFile = ../../secrets/tala.yaml;
      owner = "root";
      group = "root";
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/authentik 0750 root root -"
      "d /var/lib/authentik/media 0750 1000 1000 -"
      "d /var/lib/authentik/certs 0750 1000 1000 -"
      "d /var/lib/authentik/templates 0750 1000 1000 -"
    ];

    systemd.services.authentik-db-init = {
      description = "Sync Authentik PostgreSQL role password from SOPS secret";
      after = [
        "postgresql.service"
        "postgresql-setup.service"
      ];
      requires = [
        "postgresql.service"
        "postgresql-setup.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        LoadCredential = "authentik_env:${config.sops.secrets."authentik_env".path}";
        ExecStart = lib.getExe dbInitScript;
      };
    };

    virtualisation.oci-containers.containers = {
      authentik-server = {
        inherit (cfg) image;
        cmd = [ "server" ];
        environmentFiles = [ config.sops.secrets."authentik_env".path ];
        environment = commonEnv // {
          AUTHENTIK_LISTEN__HTTP = "0.0.0.0:${toString cfg.port}";
          AUTHENTIK_LISTEN__HTTPS = "";
          AUTHENTIK_LISTEN__METRICS = "127.0.0.1:9300";
        };
        volumes = [
          "/var/lib/authentik/media:/media"
          "/var/lib/authentik/templates:/templates"
          "${./authentik-family-flow.html}:/templates/if/flow.html:ro"
          # Original G from Google's Sign in with Google branding guidelines.
          "${./authentik-google-g.png}:/web/authentik/sources/family-google-g.png:ro"
        ];
        extraOptions = [
          "--network=host"
        ];
      };

      authentik-worker = {
        inherit (cfg) image;
        cmd = [ "worker" ];
        environmentFiles = [ config.sops.secrets."authentik_env".path ];
        environment = commonEnv // {
          AUTHENTIK_LISTEN__HTTP = "127.0.0.1:9001";
          AUTHENTIK_LISTEN__HTTPS = "";
          AUTHENTIK_LISTEN__METRICS = "127.0.0.1:9301";
        };
        volumes = [
          "/var/lib/authentik/media:/media"
          "/var/lib/authentik/certs:/certs"
          "${./authentik-family-brand.yaml}:/blueprints/custom/faragao-family.yaml:ro"
          "/var/lib/authentik/templates:/templates"
        ];
        extraOptions = [
          "--network=host"
        ];
      };
    };

    systemd.services.docker-authentik-server = {
      after = [
        "postgresql.service"
        "postgresql-setup.service"
        "authentik-db-init.service"
        "docker.service"
        "network-online.target"
      ];
      requires = [
        "postgresql.service"
        "postgresql-setup.service"
        "authentik-db-init.service"
        "docker.service"
      ];
      onFailure = lib.mkIf config.services.faragao-netwatch.enable [
        "netwatch-unit-alert@docker-authentik-server.service"
      ];
    };

    systemd.services.docker-authentik-worker = {
      after = [
        "postgresql.service"
        "postgresql-setup.service"
        "authentik-db-init.service"
        "docker.service"
        "network-online.target"
      ];
      requires = [
        "postgresql.service"
        "postgresql-setup.service"
        "authentik-db-init.service"
        "docker.service"
      ];
      onFailure = lib.mkIf config.services.faragao-netwatch.enable [
        "netwatch-unit-alert@docker-authentik-worker.service"
      ];
    };

    systemd.services.postgresql = lib.mkIf config.services.faragao-netwatch.enable {
      onFailure = [ "netwatch-unit-alert@postgresql.service" ];
    };

    networking.firewall.extraCommands = lib.concatMapStringsSep "\n" (cidr: ''
      iptables -w -A nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.port} -j nixos-fw-accept
    '') cfg.allowedProxyCIDRs;

    networking.firewall.extraStopCommands = lib.concatMapStringsSep "\n" (cidr: ''
      iptables -w -D nixos-fw -s ${cidr} -p tcp --dport ${toString cfg.port} -j nixos-fw-accept 2>/dev/null || true
    '') cfg.allowedProxyCIDRs;
  };
}
