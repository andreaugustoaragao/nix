{ config, pkgs, ... }:
let
  textfileDir = "/var/lib/node_exporter/textfile";

  logCanaryScript = pkgs.writeShellApplication {
    name = "faragao-log-canary";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      set -euo pipefail
      exec logger -t faragao-log-canary "CANARY_OK device=maui"
    '';
  };

  mauiLokiCanary = pkgs.writeShellApplication {
    name = "maui-loki-canary";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gawk
      jq
    ];
    text = ''
      set -euo pipefail

      token="$(awk -F= '/^LOKI_QUERY_TOKEN=/{print substr($0, index($0, "=") + 1); exit}' "$CREDENTIALS_DIRECTORY/loki_query_env" | tr -d '\r\n')"
      if [[ -z "$token" ]]; then
        echo "missing LOKI_QUERY_TOKEN in loki_query_env credential" >&2
        exit 1
      fi

      mkdir -p ${textfileDir}
      tmp="$(mktemp ${textfileDir}/.loki_coverage.prom.XXXXXX)"
      trap 'rm -f "$tmp"' EXIT

      now="$(date -u +%s)"
      start_ns="$(( (now - 1800) * 1000000000 ))"
      end_ns="$(( (now + 60) * 1000000000 ))"
      loki_base="http://192.168.40.10:3101"

      query_ok=1
      declare -A canary_found canary_last_seen canary_age
      for dev in tala maui; do
        logql="{device=\"$dev\",service=\"faragao-log-canary\"} |= \"CANARY_OK\""
        resp=""
        if resp="$(curl -fsSG --max-time 10 \
          -H "Authorization: Bearer $token" \
          --data-urlencode "query=$logql" \
          --data-urlencode "start=$start_ns" \
          --data-urlencode "end=$end_ns" \
          --data-urlencode "limit=1" \
          --data-urlencode "direction=backward" \
          "$loki_base/loki/api/v1/query_range" 2>/dev/null)" && \
          jq -e '.status == "success"' <<<"$resp" >/dev/null 2>&1; then
          ts_sec="$(jq -r '([.data.result[]?.values[]?[0]] | map(if (length > 9) then (.[0:length-9] | tonumber? // 0) else 0 end) | max) // 0' <<<"$resp")"
          if [[ "$ts_sec" -gt 0 ]]; then
            canary_found["$dev"]=1
            canary_last_seen["$dev"]="$ts_sec"
            if [[ "$now" -gt "$ts_sec" ]]; then
              canary_age["$dev"]="$(( now - ts_sec ))"
            else
              canary_age["$dev"]=0
            fi
          else
            canary_found["$dev"]=0
            canary_last_seen["$dev"]=0
            canary_age["$dev"]=999999
          fi
        else
          query_ok=0
          canary_found["$dev"]=0
          canary_last_seen["$dev"]=0
          canary_age["$dev"]=999999
        fi
      done

      declare -A dev_counts
      expected_devices=(
        maui
        tala
        teka
        chief-tui-opn
        chief-tui
        tamatoa
        ruckus-basement
        ruckus-secondfloor
      )
      for dev in "''${expected_devices[@]}"; do
        dev_counts["$dev"]=0
      done

      counts_resp=""
      if counts_resp="$(curl -fsSG --max-time 10 \
        -H "Authorization: Bearer $token" \
        --data-urlencode 'query=sum by (device) (count_over_time({device=~".+"}[24h]))' \
        "$loki_base/loki/api/v1/query" 2>/dev/null)" && \
        jq -e '.status == "success"' <<<"$counts_resp" >/dev/null 2>&1; then
        while IFS=$'\t' read -r d c; do
          [[ -n "$d" ]] && dev_counts["$d"]="$c"
        done < <(jq -r '.data.result[]? | "\(.metric.device // "")\t\((.value[1] | tonumber? // 0 | floor))"' <<<"$counts_resp")
      else
        query_ok=0
      fi

      {
        printf '# HELP loki_canary_collector_timestamp_seconds Unix timestamp of latest Loki canary/coverage collector run.\n'
        printf '# TYPE loki_canary_collector_timestamp_seconds gauge\n'
        printf 'loki_canary_collector_timestamp_seconds %s\n' "$now"

        printf '# HELP loki_query_ok Whether maui successfully queried the authenticated Loki gateway on tala (1=ok, 0=failed).\n'
        printf '# TYPE loki_query_ok gauge\n'
        printf 'loki_query_ok %s\n' "$query_ok"

        printf '# HELP loki_canary_found Whether a recent faragao-log-canary entry was found in Loki within 30m (1=found, 0=missing).\n'
        printf '# TYPE loki_canary_found gauge\n'
        for dev in tala maui; do
          printf 'loki_canary_found{device="%s"} %s\n' "$dev" "''${canary_found[$dev]}"
        done

        printf '# HELP loki_canary_last_seen_seconds Unix timestamp of latest verified canary log line in Loki (0 if missing).\n'
        printf '# TYPE loki_canary_last_seen_seconds gauge\n'
        for dev in tala maui; do
          printf 'loki_canary_last_seen_seconds{device="%s"} %s\n' "$dev" "''${canary_last_seen[$dev]}"
        done

        printf '# HELP loki_canary_age_seconds Age in seconds of latest verified canary log line in Loki.\n'
        printf '# TYPE loki_canary_age_seconds gauge\n'
        for dev in tala maui; do
          printf 'loki_canary_age_seconds{device="%s"} %s\n' "$dev" "''${canary_age[$dev]}"
        done

        printf '# HELP loki_device_logs_24h Count of log lines indexed in Loki over the last 24h per expected infrastructure device.\n'
        printf '# TYPE loki_device_logs_24h gauge\n'
        for dev in "''${expected_devices[@]}"; do
          printf 'loki_device_logs_24h{device="%s"} %s\n' "$dev" "''${dev_counts[$dev]}"
        done
      } > "$tmp"

      chmod 0644 "$tmp"
      mv -f "$tmp" "${textfileDir}/loki_coverage.prom"
      trap - EXIT
    '';
  };
in
{
  services.alloy = {
    enable = true;
    environmentFile = config.sops.secrets.loki_push_env.path;
    extraFlags = [
      "--server.http.listen-addr=127.0.0.1:12345"
      "--disable-reporting"
      "--storage.path=/var/lib/alloy"
    ];
  };

  environment.etc."alloy/config.alloy".text = ''
    loki.relabel "maui_journal_rules" {
      forward_to = []

      rule {
        source_labels = ["__journal__systemd_unit", "__journal_syslog_identifier"]
        separator     = ";"
        regex         = "^(nginx\\.service|grafana\\.service|prometheus\\.service|alertmanager\\.service|continuwuity\\.service|vaultwarden\\.service|samba-smbd\\.service|sshd\\.service|nixos-upgrade\\.service|acme-faragao\\.net\\.service|maui-storage-metrics\\.service|maui-external-probe\\.service|maui-fleet-versions\\.service|maui-loki-canary\\.service|alloy\\.service|faragao-log-canary\\.service);.*|.*;(faragao-log-canary|sudo|sshd)$"
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

    loki.source.journal "maui_journal" {
      max_age       = "12h"
      labels        = {
        device = "maui",
        role   = "server",
      }
      relabel_rules = loki.relabel.maui_journal_rules.rules
      forward_to    = [loki.process.redact_secrets.receiver]
    }

    // Redact bearer tokens, auth headers, credentials, and secret URL params before leaving maui.
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

      forward_to = [loki.write.tala_loki.receiver]
    }

    loki.write "tala_loki" {
      endpoint {
        url                 = "http://192.168.40.10:3101/loki/api/v1/push"
        bearer_token        = sys.env("LOKI_PUSH_TOKEN")
        min_backoff_period  = "1s"
        max_backoff_period  = "60s"
        max_backoff_retries = 20
      }
    }
  '';

  systemd = {
    services = {
      faragao-log-canary = {
        description = "Emit synthetic log canary marker into journald on maui";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${logCanaryScript}/bin/faragao-log-canary";
        };
      };

      maui-loki-canary = {
        description = "Verify Loki canary freshness and per-device 24h log coverage";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          LoadCredential = "loki_query_env:${config.sops.secrets.loki_query_env.path}";
          ExecStart = "${mauiLokiCanary}/bin/maui-loki-canary";
        };
      };
    };

    timers = {
      faragao-log-canary = {
        description = "Periodic Loki end-to-end log canary on maui";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = "5m";
          AccuracySec = "10s";
        };
      };

      maui-loki-canary = {
        description = "Periodic Loki canary and log coverage verification on maui";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "45s";
          OnUnitActiveSec = "60s";
          AccuracySec = "10s";
        };
      };
    };
  };
}
