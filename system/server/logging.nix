{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.faragao-logging;

  alloyConfigText = ''
    // Allowlisted local systemd journals on tala
    loki.relabel "tala_journal_rules" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit", "__journal_syslog_identifier"]
        separator     = ";"
        regex         = "^(docker-authentik-server\\.service|docker-authentik-worker\\.service|postgresql\\.service|netwatch\\.service|loki\\.service|alloy\\.service|nginx\\.service|sshd\\.service|sudo\\.service|nixos-upgrade\\.service|tala-storage-metrics\\.service|faragao-log-canary\\.service);.*|.*;(faragao-log-canary|sudo|sshd)$"
        action        = "keep"
      }

      rule {
        source_labels = ["__journal__systemd_unit"]
        regex         = "(.+)"
        target_label  = "service"
        replacement   = "$1"
      }

      rule {
        source_labels = ["service", "__journal_syslog_identifier"]
        separator     = ";"
        regex         = "^session-.*\\.scope;(.+)$"
        target_label  = "service"
        replacement   = "$1"
      }

      rule {
        source_labels = ["service", "__journal_syslog_identifier"]
        separator     = ";"
        regex         = "^;(.+)$"
        target_label  = "service"
        replacement   = "$1"
      }

      rule {
        source_labels = ["__journal_syslog_identifier"]
        regex         = "^(faragao-log-canary)$"
        target_label  = "service"
        replacement   = "$1"
      }

      rule {
        source_labels = ["service"]
        regex         = "^$"
        target_label  = "service"
        replacement   = "journal"
      }

      rule {
        source_labels = ["__journal_priority_keyword"]
        regex         = "(.+)"
        target_label  = "severity"
        replacement   = "$1"
      }
    }

    loki.source.journal "tala_journal" {
      max_age       = "12h"
      labels        = {
        device = "tala",
        role   = "security-host",
      }
      relabel_rules = loki.relabel.tala_journal_rules.rules
      forward_to    = [loki.process.redact_secrets.receiver]
    }

    // RFC 5424 over TCP :5515 (chief-tui-opn and teka)
    loki.relabel "syslog_tcp_rules" {
      forward_to = []

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^(192\\.168\\.100\\.2|192\\.168\\.40\\.4)$"
        action        = "keep"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.100\\.2$"
        target_label  = "device"
        replacement   = "chief-tui-opn"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.100\\.2$"
        target_label  = "role"
        replacement   = "firewall"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.40\\.4$"
        target_label  = "device"
        replacement   = "teka"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.40\\.4$"
        target_label  = "role"
        replacement   = "nas"
      }

      rule {
        source_labels = ["__syslog_message_app_name"]
        regex         = "(.+)"
        target_label  = "service"
        replacement   = "$1"
      }

      rule {
        source_labels = ["service"]
        regex         = "^$"
        target_label  = "service"
        replacement   = "syslog"
      }

      rule {
        source_labels = ["__syslog_message_severity"]
        regex         = "(.+)"
        target_label  = "severity"
        replacement   = "$1"
      }
    }

    loki.source.syslog "tcp_rfc5424" {
      listener {
        address             = "0.0.0.0:5515"
        protocol            = "tcp"
        syslog_format       = "rfc5424"
        use_rfc5424_message = true
        idle_timeout        = "120s"
        labels              = {
          transport = "syslog-tcp-5424",
        }
      }
      relabel_rules = loki.relabel.syslog_tcp_rules.rules
      forward_to    = [loki.process.redact_secrets.receiver]
    }

    // RFC 3164 over UDP :514 (tamatoa, chief-tui, ruckus-basement, ruckus-secondfloor)
    loki.relabel "syslog_udp_rules" {
      forward_to = []

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^(192\\.168\\.100\\.1|192\\.168\\.40\\.1|192\\.168\\.100\\.3|192\\.168\\.100\\.51|192\\.168\\.100\\.53)$"
        action        = "keep"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.(100|40)\\.1$"
        target_label  = "device"
        replacement   = "tamatoa"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.(100|40)\\.1$"
        target_label  = "role"
        replacement   = "switch"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.100\\.3$"
        target_label  = "device"
        replacement   = "chief-tui"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.100\\.3$"
        target_label  = "role"
        replacement   = "standby-router"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.100\\.51$"
        target_label  = "device"
        replacement   = "ruckus-basement"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.100\\.51$"
        target_label  = "role"
        replacement   = "ap-member"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.100\\.53$"
        target_label  = "device"
        replacement   = "ruckus-secondfloor"
      }

      rule {
        source_labels = ["__syslog_connection_ip_address"]
        regex         = "^192\\.168\\.100\\.53$"
        target_label  = "role"
        replacement   = "ap-controller"
      }

      rule {
        source_labels = ["__syslog_message_app_name"]
        regex         = "(.+)"
        target_label  = "service"
        replacement   = "$1"
      }

      rule {
        source_labels = ["service"]
        regex         = "^$"
        target_label  = "service"
        replacement   = "syslog"
      }

      rule {
        source_labels = ["__syslog_message_severity"]
        regex         = "(.+)"
        target_label  = "severity"
        replacement   = "$1"
      }
    }

    loki.source.syslog "udp_rfc3164" {
      listener {
        address       = "0.0.0.0:514"
        protocol      = "udp"
        syslog_format = "rfc3164"
        labels        = {
          transport = "syslog-udp-3164",
        }
      }
      relabel_rules = loki.relabel.syslog_udp_rules.rules
      forward_to    = [loki.process.redact_secrets.receiver]
    }

    // Scrub bearer tokens, auth headers, credentials, and secret query params before storage.
    loki.process "redact_secrets" {
      stage.replace {
        expression = "(?i)Bearer\\s+([^\\s\"'&;,]+)"
        replace    = "[REDACTED]"
      }

      stage.replace {
        expression = "(?i)Authorization\\s*[:=]\\s*(?:Basic|Token|Bearer)?\\s*([^\\s\"'&;,]+)"
        replace    = "[REDACTED]"
      }

      stage.replace {
        expression = "(?i)(?:password|passwd|pwd|client_secret|access_token|refresh_token|id_token|api_key|apikey|secret|token|session_id|sessionid|cookie|set-cookie)\\s*[:=]\\s*[\"']?([^\\s\"'&;,]+)"
        replace    = "[REDACTED]"
      }

      stage.replace {
        expression = "(?i)[?&](?:token|code|secret|key|password|access_token|id_token|session|auth)=([^\\s&\"']+)"
        replace    = "[REDACTED]"
      }

      forward_to = [loki.write.local_loki.receiver]
    }

    loki.write "local_loki" {
      endpoint {
        url                = "http://127.0.0.1:3100/loki/api/v1/push"
        min_backoff_period = "1s"
        max_backoff_period = "30s"
        max_backoff_retries = 20
      }
    }
  '';

  checkedAlloyConfig =
    pkgs.runCommand "tala-alloy-config-checked"
      {
        nativeBuildInputs = [ config.services.alloy.package ];
      }
      ''
        mkdir -p conf
        cat <<'EOF' > conf/config.alloy
        ${alloyConfigText}
        EOF
        alloy validate conf
        touch "$out"
      '';

  lokiGatewayAuthScript = pkgs.writeShellApplication {
    name = "loki-gateway-auth";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
    ];
    text = ''
      set -euo pipefail

      env_file="$CREDENTIALS_DIRECTORY/loki_gateway_env"
      push_tok="$(awk -F= '/^LOKI_PUSH_TOKEN=/{print substr($0, index($0, "=") + 1); exit}' "$env_file" | tr -d '\r\n')"
      query_tok="$(awk -F= '/^LOKI_QUERY_TOKEN=/{print substr($0, index($0, "=") + 1); exit}' "$env_file" | tr -d '\r\n')"

      if [[ ! "$push_tok" =~ ^[A-Za-z0-9_-]{32,}$ ]]; then
        echo "invalid or missing LOKI_PUSH_TOKEN in loki_gateway_env" >&2
        exit 1
      fi
      if [[ ! "$query_tok" =~ ^[A-Za-z0-9_-]{32,}$ ]]; then
        echo "invalid or missing LOKI_QUERY_TOKEN in loki_gateway_env" >&2
        exit 1
      fi
      if [[ "$push_tok" == "$query_tok" ]]; then
        echo "LOKI_PUSH_TOKEN and LOKI_QUERY_TOKEN must be distinct" >&2
        exit 1
      fi

      install -d -m 0750 -o root -g nginx /run/loki-gateway
      tmp="$(mktemp /run/loki-gateway/.auth.conf.XXXXXX)"
      trap 'rm -f "$tmp"' EXIT

      {
        printf "map \$http_authorization \$loki_push_ok {\n"
        printf '    default 0;\n'
        printf '    "Bearer %s" 1;\n' "$push_tok"
        printf '}\n'
        printf "map \$http_authorization \$loki_query_ok {\n"
        printf '    default 0;\n'
        printf '    "Bearer %s" 1;\n' "$query_tok"
        printf '}\n'
      } > "$tmp"

      chmod 0640 "$tmp"
      chown root:nginx "$tmp"
      mv -f "$tmp" /run/loki-gateway/auth.conf
      trap - EXIT
    '';
  };

  logCanaryScript = pkgs.writeShellApplication {
    name = "faragao-log-canary";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      set -euo pipefail
      exec logger -t faragao-log-canary "CANARY_OK device=tala"
    '';
  };

  tcpSyslogCIDRs = [
    "192.168.100.2/32" # chief-tui-opn
    "192.168.40.4/32" # teka
  ];

  udpSyslogCIDRs = [
    "192.168.100.1/32" # tamatoa ve 100
    "192.168.40.1/32" # tamatoa ve 40
    "192.168.100.3/32" # chief-tui
    "192.168.100.51/32" # ruckus-basement
    "192.168.100.53/32" # ruckus-secondfloor
  ];
in
{
  options.services.faragao-logging = {
    enable = lib.mkEnableOption "Centralized Loki and Alloy logging pipeline with authenticated gateway on tala";
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."loki_gateway_env" = {
      sopsFile = ../../secrets/tala.yaml;
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [
        "loki-gateway-auth.service"
        "nginx.service"
      ];
    };

    services = {
      loki = {
        enable = true;
        configuration = {
          auth_enabled = false;
          analytics.reporting_enabled = false;
          server = {
            http_listen_address = "127.0.0.1";
            http_listen_port = 3100;
            grpc_listen_address = "127.0.0.1";
            grpc_listen_port = 9095;
            log_level = "warn";
          };
          common = {
            path_prefix = "/var/lib/loki";
            instance_addr = "127.0.0.1";
            instance_interface_names = [ "lo" ];
            replication_factor = 1;
            ring = {
              instance_addr = "127.0.0.1";
              kvstore.store = "inmemory";
            };
          };
          frontend.address = "127.0.0.1";
          schema_config.configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
          storage_config.filesystem.directory = "/var/lib/loki/chunks";
          limits_config = {
            retention_period = "744h"; # 31 days
            allow_structured_metadata = true;
            volume_enabled = true;
            ingestion_rate_mb = 8;
            ingestion_burst_size_mb = 16;
            per_stream_rate_limit = "2MB";
            per_stream_rate_limit_burst = "4MB";
            max_streams_per_user = 2000;
            reject_old_samples = true;
            reject_old_samples_max_age = "168h";
          };
          compactor = {
            working_directory = "/var/lib/loki/compactor";
            delete_request_store = "filesystem";
            retention_enabled = true;
            compaction_interval = "10m";
            retention_delete_delay = "2h";
            retention_delete_worker_count = 150;
          };
        };
      };

      nginx = {
        enable = true;
        validateConfigFile = false;
        recommendedProxySettings = true;
        recommendedOptimisation = true;
        serverTokens = false;
        mapHashBucketSize = 128;
        appendHttpConfig = "include /run/loki-gateway/auth.conf;";
        virtualHosts."loki-gateway" = {
          default = true;
          listen = [
            {
              addr = "192.168.40.10";
              port = 3101;
            }
            {
              addr = "127.0.0.1";
              port = 3101;
            }
          ];
          locations = {
            "= /loki/api/v1/push" = {
              proxyPass = "http://127.0.0.1:3100";
              extraConfig = ''
                if ($request_method != POST) { return 403; }
                if ($loki_push_ok = 0) { return 401; }
                client_max_body_size 16m;
              '';
            };
            "= /ready" = {
              proxyPass = "http://127.0.0.1:3100";
              extraConfig = ''
                if ($request_method !~ ^(GET|HEAD)$) { return 403; }
                if ($loki_query_ok = 0) { return 401; }
              '';
            };
            "~ ^/loki/api/v1/(query|query_range|labels|label/[^/]+/values|series|index/stats|index/volume|index/volume_range|detected_labels|detected_fields|patterns|status/buildinfo)$" =
              {
                proxyPass = "http://127.0.0.1:3100";
                extraConfig = ''
                  if ($request_method !~ ^(GET|HEAD)$) { return 403; }
                  if ($loki_query_ok = 0) { return 401; }
                '';
              };
            "= /metrics/loki" = {
              proxyPass = "http://127.0.0.1:3100/metrics";
              extraConfig = ''
                allow 127.0.0.1;
                allow 192.168.40.3;
                deny all;
                if ($request_method !~ ^(GET|HEAD)$) { return 403; }
              '';
            };
            "= /metrics/alloy" = {
              proxyPass = "http://127.0.0.1:12345/metrics";
              extraConfig = ''
                allow 127.0.0.1;
                allow 192.168.40.3;
                deny all;
                if ($request_method !~ ^(GET|HEAD)$) { return 403; }
              '';
            };
            "/" = {
              return = "403";
            };
          };
        };
      };

      alloy = {
        enable = true;
        extraFlags = [
          "--server.http.listen-addr=127.0.0.1:12345"
          "--disable-reporting"
          "--storage.path=/var/lib/alloy"
        ];
      };
    };

    environment.etc."alloy/config.alloy".text = alloyConfigText;
    system.checks = [ checkedAlloyConfig ];

    systemd = {
      services = {
        loki-gateway-auth = {
          description = "Render Nginx bearer-token auth maps for Loki read/write gateway";
          before = [ "nginx.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "root";
            Group = "nginx";
            RuntimeDirectory = "loki-gateway";
            RuntimeDirectoryMode = "0750";
            LoadCredential = "loki_gateway_env:${config.sops.secrets."loki_gateway_env".path}";
            ExecStart = lib.getExe lokiGatewayAuthScript;
          };
        };

        loki = {
          onFailure = lib.mkIf config.services.faragao-netwatch.enable [ "netwatch-unit-alert@loki.service" ];
        };

        nginx = {
          after = [
            "loki-gateway-auth.service"
            "loki.service"
          ];
          requires = [ "loki-gateway-auth.service" ];
          onFailure = lib.mkIf config.services.faragao-netwatch.enable [
            "netwatch-unit-alert@nginx.service"
          ];
        };

        alloy = {
          after = [
            "loki.service"
            "network-online.target"
          ];
          wants = [
            "loki.service"
            "network-online.target"
          ];
          serviceConfig = {
            AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
            CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
          };
          onFailure = lib.mkIf config.services.faragao-netwatch.enable [
            "netwatch-unit-alert@alloy.service"
          ];
        };

        faragao-log-canary = {
          description = "Emit synthetic log canary marker into journald on tala";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe logCanaryScript;
          };
        };
      };

      timers.faragao-log-canary = {
        description = "Periodic Loki end-to-end log canary on tala";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = "5m";
          AccuracySec = "10s";
        };
      };
    };

    networking.firewall = {
      extraCommands = ''
        iptables -w -A nixos-fw -s 192.168.40.3/32 -p tcp --dport 3101 -j nixos-fw-accept
      ''
      + lib.concatMapStringsSep "\n" (cidr: ''
        iptables -w -A nixos-fw -s ${cidr} -p tcp --dport 5515 -j nixos-fw-accept
      '') tcpSyslogCIDRs
      + "\n"
      + lib.concatMapStringsSep "\n" (cidr: ''
        iptables -w -A nixos-fw -s ${cidr} -p udp --dport 514 -j nixos-fw-accept
      '') udpSyslogCIDRs;

      extraStopCommands = ''
        iptables -w -D nixos-fw -s 192.168.40.3/32 -p tcp --dport 3101 -j nixos-fw-accept 2>/dev/null || true
      ''
      + lib.concatMapStringsSep "\n" (cidr: ''
        iptables -w -D nixos-fw -s ${cidr} -p tcp --dport 5515 -j nixos-fw-accept 2>/dev/null || true
      '') tcpSyslogCIDRs
      + "\n"
      + lib.concatMapStringsSep "\n" (cidr: ''
        iptables -w -D nixos-fw -s ${cidr} -p udp --dport 514 -j nixos-fw-accept 2>/dev/null || true
      '') udpSyslogCIDRs;
    };
  };
}
