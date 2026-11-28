{
  config,
  pkgs,
  ...
}:
let
  yaml = pkgs.formats.yaml { };
  textfileDir = "/var/lib/node_exporter/textfile";

  # Expected source inventory independent of Prometheus scrape target discovery so
  # removing a target cannot make a fleet coverage panel turn green.
  fleetInventoryProm = pkgs.writeText "fleet_inventory.prom" ''
    # HELP fleet_expected_source Expected infrastructure sources (1=always-on infra, 0=conditional personal host).
    # TYPE fleet_expected_source gauge
    fleet_expected_source{device="maui",role="server",tier="infra"} 1
    fleet_expected_source{device="tala",role="server",tier="infra"} 1
    fleet_expected_source{device="teka",role="nas",tier="infra"} 1
    fleet_expected_source{device="chief-tui-opn",role="firewall",tier="infra"} 1
    fleet_expected_source{device="chief-tui",role="standby-router",tier="infra"} 1
    fleet_expected_source{device="tamatoa",role="switch",tier="infra"} 1
    fleet_expected_source{device="ruckus-basement",role="ap-member",tier="infra"} 1
    fleet_expected_source{device="ruckus-secondfloor",role="ap-controller",tier="infra"} 1
    fleet_expected_source{device="workstation",role="workstation",tier="conditional"} 0
  '';

  mauiStorageMetrics = pkgs.writeShellApplication {
    name = "maui-storage-metrics";
    runtimeInputs = with pkgs; [
      btrfs-progs
      coreutils
      gawk
      gnused
      jq
      openssl
      smartmontools
    ];
    text = ''
      set -euo pipefail

      mkdir -p ${textfileDir}
      tmp="$(mktemp ${textfileDir}/.storage.prom.XXXXXX)"
      trap 'rm -f "$tmp"' EXIT

      now="$(date -u +%s)"
      prom_label() {
        local v="$1"
        v="''${v//\\/\\\\}"
        v="''${v//\"/\\\"}"
        printf '%s' "$v"
      }

      collect_smart_device() {
        local dev="$1"
        if [[ ! -b "$dev" ]]; then
          return 0
        fi

        local json="" out="" out_sat=""
        if out="$(smartctl -j -i -H -A "$dev" 2>/dev/null || true)" && jq -e '.smart_status.passed != null' <<<"$out" >/dev/null 2>&1; then
          json="$out"
        elif out_sat="$(smartctl -j -i -H -A -d sat "$dev" 2>/dev/null || true)" && jq -e '.smart_status.passed != null' <<<"$out_sat" >/dev/null 2>&1; then
          json="$out_sat"
        elif [[ -n "$out" ]] && jq -e . <<<"$out" >/dev/null 2>&1; then
          json="$out"
        fi

        local model="unknown"
        if [[ -n "$json" ]]; then
          model="$(jq -r '(.model_name // .scsi_model_name // "unknown")' <<<"$json")"
        fi
        local dev_lbl model_lbl
        dev_lbl="$(prom_label "$dev")"
        model_lbl="$(prom_label "$model")"

        if [[ -n "$json" ]] && jq -e '.smart_status.passed != null' <<<"$json" >/dev/null 2>&1; then
          printf 'smart_device_supported{device="%s",model="%s"} 1\n' "$dev_lbl" "$model_lbl"
          local healthy temp reallocated pending uncorrectable pct_used
          healthy="$(jq -r 'if .smart_status.passed then 1 else 0 end' <<<"$json")"
          printf 'smart_device_healthy{device="%s",model="%s"} %s\n' "$dev_lbl" "$model_lbl" "$healthy"

          temp="$(jq -r '.temperature.current // empty' <<<"$json")"
          if [[ -n "$temp" ]]; then
            printf 'smart_device_temperature_celsius{device="%s"} %s\n' "$dev_lbl" "$temp"
          fi

          reallocated="$(jq -r '([.ata_smart_attributes.table[]? | select(.id == 5) | .raw.value] | first) // empty' <<<"$json")"
          if [[ -n "$reallocated" ]]; then
            printf 'smart_device_reallocated_sectors{device="%s"} %s\n' "$dev_lbl" "$reallocated"
          fi

          pending="$(jq -r '([.ata_smart_attributes.table[]? | select(.id == 197) | .raw.value] | first) // empty' <<<"$json")"
          if [[ -n "$pending" ]]; then
            printf 'smart_device_pending_sectors{device="%s"} %s\n' "$dev_lbl" "$pending"
          fi

          uncorrectable="$(jq -r '([.ata_smart_attributes.table[]? | select(.id == 198) | .raw.value] | first) // empty' <<<"$json")"
          if [[ -n "$uncorrectable" ]]; then
            printf 'smart_device_uncorrectable_sectors{device="%s"} %s\n' "$dev_lbl" "$uncorrectable"
          fi

          pct_used="$(jq -r '(.nvme_smart_health_information_log.percentage_used // ([.ata_smart_attributes.table[]? | select(.id == 231 and (.name | test("Life_Left|Remain"; "i"))) | (100 - .value)] | first)) // empty' <<<"$json")"
          if [[ -n "$pct_used" ]]; then
            printf 'smart_device_percentage_used{device="%s"} %s\n' "$dev_lbl" "$pct_used"
          fi
        else
          printf 'smart_device_supported{device="%s",model="%s"} 0\n' "$dev_lbl" "$model_lbl"
        fi
      }

      {
        printf '# HELP storage_metrics_timestamp_seconds Unix timestamp of latest storage/SMART collector run.\n'
        printf '# TYPE storage_metrics_timestamp_seconds gauge\n'
        printf 'storage_metrics_timestamp_seconds %s\n' "$now"

        printf '# HELP smart_device_supported Whether SMART health data is readable for this block device.\n'
        printf '# TYPE smart_device_supported gauge\n'
        printf '# HELP smart_device_healthy SMART overall health status (1=PASSED, 0=FAILED).\n'
        printf '# TYPE smart_device_healthy gauge\n'
        printf '# HELP smart_device_temperature_celsius Current drive temperature in Celsius.\n'
        printf '# TYPE smart_device_temperature_celsius gauge\n'
        printf '# HELP smart_device_reallocated_sectors ATA attribute 5 reallocated sector count.\n'
        printf '# TYPE smart_device_reallocated_sectors gauge\n'
        printf '# HELP smart_device_pending_sectors ATA attribute 197 current pending sector count.\n'
        printf '# TYPE smart_device_pending_sectors gauge\n'
        printf '# HELP smart_device_uncorrectable_sectors ATA attribute 198 offline uncorrectable sector count.\n'
        printf '# TYPE smart_device_uncorrectable_sectors gauge\n'
        printf '# HELP smart_device_percentage_used Estimated percentage of rated SSD endurance used.\n'
        printf '# TYPE smart_device_percentage_used gauge\n'

        for dev in /dev/sda /dev/sdb /dev/sdc; do
          collect_smart_device "$dev"
        done

        if mountpoint_out="$(btrfs device stats /data 2>/dev/null)"; then
          printf '# HELP btrfs_device_errors_total Btrfs cumulative device I/O and corruption error counters.\n'
          printf '# TYPE btrfs_device_errors_total gauge\n'
          awk '
            match($0, /^\[([^\]]+)\]\.([a-z_]+)[ \t]+([0-9]+)/, m) {
              printf "btrfs_device_errors_total{mount=\"/data\",device=\"%s\",error_type=\"%s\"} %s\n", m[1], m[2], m[3]
            }
          ' <<<"$mountpoint_out"
        fi

        if usage_out="$(btrfs filesystem usage -b /data 2>/dev/null)"; then
          printf '# HELP btrfs_device_missing Missing device count on Btrfs filesystem.\n'
          printf '# TYPE btrfs_device_missing gauge\n'
          printf '# HELP btrfs_filesystem_size_bytes Total raw size of Btrfs filesystem devices.\n'
          printf '# TYPE btrfs_filesystem_size_bytes gauge\n'
          printf '# HELP btrfs_filesystem_unallocated_bytes Unallocated raw bytes remaining on Btrfs filesystem.\n'
          printf '# TYPE btrfs_filesystem_unallocated_bytes gauge\n'
          printf '# HELP btrfs_filesystem_free_estimated_bytes Estimated free usable bytes on Btrfs filesystem.\n'
          printf '# TYPE btrfs_filesystem_free_estimated_bytes gauge\n'
          awk '
            /Device size:/        { printf "btrfs_filesystem_size_bytes{mount=\"/data\"} %s\n", $NF }
            /Device unallocated:/ { printf "btrfs_filesystem_unallocated_bytes{mount=\"/data\"} %s\n", $NF }
            /Device missing:/     { printf "btrfs_device_missing{mount=\"/data\"} %s\n", $NF }
            match($0, /Free \(estimated\):[ \t]+([0-9]+)/, m) {
              printf "btrfs_filesystem_free_estimated_bytes{mount=\"/data\"} %s\n", m[1]
            }
          ' <<<"$usage_out"
        fi

        if [[ -r /var/lib/acme/faragao.net/fullchain.pem ]]; then
          cert_end="$(openssl x509 -in /var/lib/acme/faragao.net/fullchain.pem -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
          if [[ -n "$cert_end" ]] && cert_epoch="$(date -u -d "$cert_end" +%s 2>/dev/null)"; then
            printf '# HELP acme_cert_not_after_seconds Unix timestamp when local ACME wildcard cert expires.\n'
            printf '# TYPE acme_cert_not_after_seconds gauge\n'
            printf 'acme_cert_not_after_seconds{cert="faragao.net"} %s\n' "$cert_epoch"
          fi
        fi
      } > "$tmp"

      chmod 0644 "$tmp"
      mv -f "$tmp" "${textfileDir}/storage.prom"
      trap - EXIT
    '';
  };

  mauiExternalProbe = pkgs.writeShellApplication {
    name = "maui-external-probe";
    runtimeInputs = with pkgs; [
      bind.dnsutils
      coreutils
      curl
      gnugrep
      gnused
      openssl
    ];
    text = ''
      set -euo pipefail

      mkdir -p ${textfileDir}
      tmp="$(mktemp ${textfileDir}/.external_probes.prom.XXXXXX)"
      body_tmp="$(mktemp)"
      trap 'rm -f "$tmp" "$body_tmp"' EXIT

      now="$(date -u +%s)"

      probe_public() {
        local service="$1" host="$2" path="$3" expect_substr="$4"
        local ip="" code="000" dur="0" ok="0" cert_epoch="0" cert_end=""

        ip="$(dig +short +time=5 +tries=1 @1.1.1.1 "$host" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)"
        if [[ -n "$ip" ]]; then
          local result
          result="$(curl -sS --max-time 15 --resolve "$host:443:$ip" -o "$body_tmp" -w '%{http_code} %{time_total}' "https://$host$path" 2>/dev/null || echo '000 0')"
          code="''${result%% *}"
          dur="''${result##* }"
          if [[ "$code" == "200" ]]; then
            if [[ -z "$expect_substr" ]] || grep -qF "$expect_substr" "$body_tmp"; then
              ok="1"
            fi
          fi
          cert_end="$(openssl s_client -connect "$ip:443" -servername "$host" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
          if [[ -n "$cert_end" ]]; then
            cert_epoch="$(date -u -d "$cert_end" +%s 2>/dev/null || echo 0)"
          fi
        fi

        printf 'external_probe_success{service="%s",host="%s",path="external-cloudflare"} %s\n' "$service" "$host" "$ok"
        printf 'external_probe_http_status{service="%s",host="%s",path="external-cloudflare"} %s\n' "$service" "$host" "$code"
        printf 'external_probe_duration_seconds{service="%s",host="%s",path="external-cloudflare"} %s\n' "$service" "$host" "$dur"
        if [[ "$cert_epoch" -gt 0 ]]; then
          printf 'external_probe_cert_expiry_seconds{service="%s",host="%s",path="external-cloudflare"} %s\n' "$service" "$host" "$cert_epoch"
        fi
      }

      {
        printf '# HELP external_probe_collector_timestamp_seconds Unix timestamp of latest public Cloudflare probe run.\n'
        printf '# TYPE external_probe_collector_timestamp_seconds gauge\n'
        printf 'external_probe_collector_timestamp_seconds %s\n' "$now"
        printf '# HELP external_probe_success Whether public Cloudflare probe resolved via @1.1.1.1 and returned valid HTTP 200.\n'
        printf '# TYPE external_probe_success gauge\n'
        printf '# HELP external_probe_http_status HTTP status code observed on external Cloudflare probe.\n'
        printf '# TYPE external_probe_http_status gauge\n'
        printf '# HELP external_probe_duration_seconds HTTP request duration on external Cloudflare probe.\n'
        printf '# TYPE external_probe_duration_seconds gauge\n'
        printf '# HELP external_probe_cert_expiry_seconds Unix timestamp when external Cloudflare edge TLS certificate expires.\n'
        printf '# TYPE external_probe_cert_expiry_seconds gauge\n'

        probe_public "vaultwarden-public" "vw.faragao.net" "/alive" ""
        probe_public "matrix-public" "matrix.faragao.net" "/_matrix/client/versions" "\"versions\""
      } > "$tmp"

      chmod 0644 "$tmp"
      mv -f "$tmp" "${textfileDir}/external_probes.prom"
      trap - EXIT
    '';
  };

  mauiFleetVersions = pkgs.writeShellApplication {
    name = "maui-fleet-versions";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gawk
      jq
      systemd
    ];
    text = ''
      set -euo pipefail

      token="$(awk -F= '/^NETWATCH_FLEET_TOKEN=/{print $2; exit}' "$CREDENTIALS_DIRECTORY/fleet_env" | tr -d "\r\n\"' ")"
      if [[ -z "$token" ]]; then
        echo "missing NETWATCH_FLEET_TOKEN in fleet_env credential" >&2
        exit 1
      fi

      prom_query() {
        curl -fsSG --max-time 10 --data-urlencode "query=$1" "http://127.0.0.1:9090/api/v1/query" 2>/dev/null || echo '{}'
      }

      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      maui_ver="$(awk -F= '/^BUILD_ID=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
      if [[ -z "$maui_ver" ]]; then
        maui_ver="$(prom_query 'node_os_info{device="maui"}' | jq -r '.data.result[0].metric.build_id // empty')"
      fi
      maui_kern="$(uname -r 2>/dev/null || true)"
      if [[ -z "$maui_kern" ]]; then
        maui_kern="$(prom_query 'node_uname_info{device="maui"}' | jq -r '.data.result[0].metric.release // empty')"
      fi
      upgrade_show="$(systemctl show nixos-upgrade.service -p Result -p ActiveExitTimestamp --value 2>/dev/null || true)"
      maui_up_res="$(printf '%s\n' "$upgrade_show" | sed -n '1p')"
      maui_up_run="$(printf '%s\n' "$upgrade_show" | sed -n '2p')"

      tamatoa_descr="$(prom_query 'sysDescr{device="tamatoa"}' | jq -r '.data.result[0].metric.sysDescr // empty')"
      teka_ver="$(prom_query 'synoDSMVersion{device="teka"}' | jq -r '.data.result[0].metric.synoDSMVersion // empty')"
      teka_model="$(prom_query 'synoModelName{device="teka"}' | jq -r '.data.result[0].metric.synoModelName // empty')"
      teka_upg="$(prom_query 'synoUpgradeAvailable{device="teka"}' | jq -r '.data.result[0].value[1] // "0"' | awk '{printf "%d", $1}')"

      payload="$(jq -n \
        --arg now "$now" \
        --arg maui_ver "$maui_ver" \
        --arg maui_kern "$maui_kern" \
        --arg maui_up_res "$maui_up_res" \
        --arg maui_up_run "$maui_up_run" \
        --arg tamatoa_descr "$tamatoa_descr" \
        --arg teka_ver "$teka_ver" \
        --arg teka_model "$teka_model" \
        --argjson teka_upg "$teka_upg" '
        [
          (if $maui_ver != "" then {
            device: "maui",
            running_version: $maui_ver,
            kernel_version: $maui_kern,
            version_source: "live_prometheus_node",
            last_checked_at: $now,
            upgrade_last_result: $maui_up_res,
            upgrade_last_run: $maui_up_run
          } else empty end),
          (if $tamatoa_descr != "" then {
            device: "tamatoa",
            running_version: (
              try ($tamatoa_descr | capture("Version (?<v>[^, ]+)").v)
              catch $tamatoa_descr
            ),
            version_source: "live_snmp",
            last_checked_at: $now
          } else empty end),
          (if ($teka_ver != "" or $teka_upg > 0) then {
            device: "teka",
            product: $teka_model,
            running_version: $teka_ver,
            version_source: "live_snmp",
            snmp_upgrade_available: $teka_upg,
            last_checked_at: $now
          } else empty end)
        ] | { reporter: "maui", collected_at: $now, devices: . }')"

      count="$(printf '%s' "$payload" | jq '.devices | length')"
      if [[ "$count" -eq 0 ]]; then
        echo "no fleet version metrics available yet from Prometheus" >&2
        exit 0
      fi

      curl -fsS --retry 2 --max-time 15 -X POST \
        "http://192.168.40.10:9400/ingest/fleet-versions" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null
    '';
  };

  blackboxConfigFile = yaml.generate "blackbox.yml" {
    modules = {
      icmp_ipv4 = {
        prober = "icmp";
        timeout = "5s";
        icmp = {
          preferred_ip_protocol = "ip4";
          ip_protocol_fallback = false;
        };
      };
      tcp_connect = {
        prober = "tcp";
        timeout = "5s";
        tcp = {
          preferred_ip_protocol = "ip4";
          ip_protocol_fallback = false;
        };
      };
      http_2xx = {
        prober = "http";
        timeout = "10s";
        http = {
          preferred_ip_protocol = "ip4";
          ip_protocol_fallback = false;
          valid_http_versions = [
            "HTTP/1.1"
            "HTTP/2.0"
          ];
          valid_status_codes = [ 200 ];
          follow_redirects = false;
        };
      };
      http_2xx_ruckus = {
        prober = "http";
        timeout = "10s";
        http = {
          preferred_ip_protocol = "ip4";
          ip_protocol_fallback = false;
          valid_http_versions = [
            "HTTP/1.1"
            "HTTP/2.0"
          ];
          valid_status_codes = [ 200 ];
          follow_redirects = false;
          fail_if_body_not_matches_regexp = [ "Unleashed" ];
        };
      };
      dns_internal = {
        prober = "dns";
        timeout = "5s";
        dns = {
          preferred_ip_protocol = "ip4";
          ip_protocol_fallback = false;
          query_name = "maui.faragao.net";
          query_type = "A";
          valid_rcodes = [ "NOERROR" ];
          validate_answer_rrs.fail_if_not_matches_regexp = [ ".*192\\.168\\.40\\.3$" ];
        };
      };
      dns_recursive = {
        prober = "dns";
        timeout = "5s";
        dns = {
          preferred_ip_protocol = "ip4";
          ip_protocol_fallback = false;
          query_name = "example.com";
          query_type = "A";
          valid_rcodes = [ "NOERROR" ];
        };
      };
      dns_public_vw = {
        prober = "dns";
        timeout = "5s";
        dns = {
          preferred_ip_protocol = "ip4";
          ip_protocol_fallback = false;
          query_name = "vw.faragao.net";
          query_type = "A";
          valid_rcodes = [ "NOERROR" ];
        };
      };
    };
  };

  prometheusRulesFile = yaml.generate "faragao-fleet-rules.yml" {
    groups = [
      {
        name = "faragao-fleet-alerts";
        rules = [
          {
            alert = "TargetDown";
            expr = "up == 0";
            "for" = "3m";
            labels.severity = "critical";
            annotations = {
              summary = "Prometheus scrape target down: {{ $labels.job }} on {{ $labels.device }} ({{ $labels.instance }})";
              description = "Scrape job {{ $labels.job }} for {{ $labels.device }} has failed for 3m.";
            };
          }
          {
            alert = "ExpectedSourceUnconfigured";
            expr = ''fleet_expected_source{tier="infra"} == 1 unless on(device) ((max by (device) (up{job=~"node|node_remote"})) or (max by (device) (probe_success{job="blackbox_icmp"})))'';
            "for" = "5m";
            labels.severity = "warning";
            annotations = {
              summary = "Expected infrastructure source missing from active scrapes: {{ $labels.device }} ({{ $labels.role }})";
              description = "Expected source {{ $labels.device }} is listed in fleet_expected_source but has no active node or ICMP metric.";
            };
          }
          {
            alert = "HostUnreachable";
            expr = ''probe_success{job="blackbox_icmp"} == 0'';
            "for" = "3m";
            labels.severity = "critical";
            annotations = {
              summary = "Infrastructure host unreachable by ICMP: {{ $labels.device }} ({{ $labels.instance }})";
              description = "ICMP probe from maui to {{ $labels.device }} ({{ $labels.instance }}, role={{ $labels.role }}) has failed for 3m.";
            };
          }
          {
            alert = "EndpointProbeFailed";
            expr = ''probe_success{job=~"blackbox_http_internal|blackbox_tcp"} == 0'';
            "for" = "3m";
            labels.severity = "critical";
            annotations = {
              summary = "Service probe failed on {{ $labels.device }}: {{ $labels.service }} ({{ $labels.instance }})";
              description = "Blackbox probe {{ $labels.job }} failed for {{ $labels.service }} on {{ $labels.device }} for 3m.";
            };
          }
          {
            alert = "ExternalPublicServiceFailed";
            expr = "external_probe_success == 0";
            "for" = "3m";
            labels.severity = "critical";
            annotations = {
              summary = "External Cloudflare HTTPS probe failed: {{ $labels.service }} ({{ $labels.host }})";
              description = "Public path probe resolved via @1.1.1.1 to {{ $labels.host }} failed for 3m.";
            };
          }
          {
            alert = "ExternalProbeCollectorStale";
            expr = "(time() - external_probe_collector_timestamp_seconds) > 300";
            "for" = "10m";
            labels.severity = "warning";
            annotations = {
              summary = "External Cloudflare probe collector stale on {{ $labels.device }}";
              description = "maui-external-probe.timer has not updated external_probes.prom within 5 minutes.";
            };
          }
          {
            alert = "DNSProbeFailed";
            expr = ''probe_success{job="blackbox_dns"} == 0'';
            "for" = "3m";
            labels.severity = "critical";
            annotations = {
              summary = "DNS resolution check failed: {{ $labels.check }} on {{ $labels.device }} ({{ $labels.instance }})";
              description = "DNS probe {{ $labels.check }} against {{ $labels.instance }} failed for 3m.";
            };
          }
          {
            alert = "SystemdUnitFailed";
            expr = ''node_systemd_unit_state{state="failed",name!~"fwupd.*|man-db.*"} == 1'';
            "for" = "2m";
            labels.severity = "critical";
            annotations = {
              summary = "Failed systemd unit on {{ $labels.device }}: {{ $labels.name }}";
              description = "systemd unit {{ $labels.name }} on {{ $labels.device }} has been in failed state for 2m.";
            };
          }
          {
            alert = "DiskSpaceWarning";
            expr = ''(node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|squashfs|overlay|fuse.*",mountpoint!~"/boot.*|/run.*"} / node_filesystem_size_bytes{fstype!~"tmpfs|ramfs|squashfs|overlay|fuse.*",mountpoint!~"/boot.*|/run.*"}) < 0.20'';
            "for" = "10m";
            labels.severity = "warning";
            annotations = {
              summary = "Filesystem below 20% free on {{ $labels.device }}: {{ $labels.mountpoint }}";
              description = "{{ $labels.device }} {{ $labels.mountpoint }} has dropped below 20% available capacity.";
            };
          }
          {
            alert = "DiskSpaceCritical";
            expr = ''(node_filesystem_avail_bytes{fstype!~"tmpfs|ramfs|squashfs|overlay|fuse.*",mountpoint!~"/boot.*|/run.*"} / node_filesystem_size_bytes{fstype!~"tmpfs|ramfs|squashfs|overlay|fuse.*",mountpoint!~"/boot.*|/run.*"}) < 0.10'';
            "for" = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "Filesystem CRITICAL (<10% free) on {{ $labels.device }}: {{ $labels.mountpoint }}";
              description = "{{ $labels.device }} {{ $labels.mountpoint }} has dropped below 10% available capacity.";
            };
          }
          {
            alert = "BtrfsDeviceErrors";
            expr = ''btrfs_device_errors_total{mount="/data"} > 0'';
            "for" = "1m";
            labels.severity = "critical";
            annotations = {
              summary = "Btrfs device errors on {{ $labels.device }} ({{ $labels.exported_device }})";
              description = "Btrfs {{ $labels.mount }} reports {{ $labels.error_type }}={{ $value }} on {{ $labels.exported_device }}.";
            };
          }
          {
            alert = "BtrfsDeviceMissing";
            expr = ''btrfs_device_missing{mount="/data"} > 0'';
            "for" = "1m";
            labels.severity = "critical";
            annotations = {
              summary = "Btrfs missing device on {{ $labels.device }} ({{ $labels.mount }})";
              description = "Btrfs {{ $labels.mount }} reports {{ $value }} missing device(s).";
            };
          }
          {
            alert = "DiskSmartUnhealthy";
            expr = "smart_device_healthy == 0";
            "for" = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "SMART health FAILED on {{ $labels.device }} {{ $labels.exported_device }} ({{ $labels.model }})";
              description = "smartctl reports FAILED health status on {{ $labels.device }} {{ $labels.exported_device }}.";
            };
          }
          {
            alert = "DiskSmartSectorErrors";
            expr = "smart_device_pending_sectors > 0 or smart_device_uncorrectable_sectors > 0";
            "for" = "15m";
            labels.severity = "warning";
            annotations = {
              summary = "SMART pending/uncorrectable sectors on {{ $labels.device }} {{ $labels.exported_device }}";
              description = "Disk {{ $labels.exported_device }} on {{ $labels.device }} reports non-zero pending or uncorrectable sectors ({{ $value }}).";
            };
          }
          {
            alert = "StorageMetricsStale";
            expr = "(time() - storage_metrics_timestamp_seconds) > 900";
            "for" = "15m";
            labels.severity = "warning";
            annotations = {
              summary = "Storage/SMART collector stale on {{ $labels.device }}";
              description = "storage.prom on {{ $labels.device }} has not updated in >15 minutes.";
            };
          }
          {
            alert = "TLSCertExpiringSoon";
            expr = ''
              ((acme_cert_not_after_seconds - time()) < 1814400)
              or ((probe_ssl_earliest_cert_expiry{job="blackbox_http_internal"} - time()) < 1814400)
              or ((external_probe_cert_expiry_seconds > 0) and ((external_probe_cert_expiry_seconds - time()) < 1814400))
              or ((netwatch_opnsense_webgui_cert_expiry_seconds > 0) and ((netwatch_opnsense_webgui_cert_expiry_seconds - time()) < 1814400))
            '';
            "for" = "30m";
            labels.severity = "warning";
            annotations = {
              summary = "TLS certificate expiring within 21 days ({{ $labels.device }} {{ $labels.cert }}{{ $labels.instance }}{{ $labels.service }})";
              description = "TLS certificate expires in under 21 days.";
            };
          }
          {
            alert = "TLSCertExpiringCritical";
            expr = ''
              ((acme_cert_not_after_seconds - time()) < 604800)
              or ((probe_ssl_earliest_cert_expiry{job="blackbox_http_internal"} - time()) < 604800)
              or ((external_probe_cert_expiry_seconds > 0) and ((external_probe_cert_expiry_seconds - time()) < 604800))
              or ((netwatch_opnsense_webgui_cert_expiry_seconds > 0) and ((netwatch_opnsense_webgui_cert_expiry_seconds - time()) < 604800))
            '';
            "for" = "15m";
            labels.severity = "critical";
            annotations = {
              summary = "TLS certificate CRITICAL (<7 days) ({{ $labels.device }} {{ $labels.cert }}{{ $labels.instance }}{{ $labels.service }})";
              description = "TLS certificate expires in under 7 days; inspect ACME renewal immediately.";
            };
          }
          {
            alert = "TekaRaidDegraded";
            expr = ''synoRaidStatus{device="teka"} > 1'';
            "for" = "2m";
            labels.severity = "critical";
            annotations = {
              summary = "Synology NAS RAID/pool degraded on {{ $labels.device }}: {{ $labels.raidName }} (status={{ $value }})";
              description = "teka storage pool {{ $labels.raidName }} reported non-Normal synoRaidStatus={{ $value }} for 2m.";
            };
          }
          {
            alert = "TekaDiskUnhealthy";
            expr = ''synoDiskStatus{device="teka"} > 1 or synoDiskHealthStatus{device="teka"} > 1'';
            "for" = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "Synology NAS physical disk warning on {{ $labels.device }}: {{ $labels.diskID }} ({{ $labels.diskModel }})";
              description = "teka physical drive {{ $labels.diskID }} reported abnormal status/SMART health ({{ $value }}).";
            };
          }
          {
            alert = "TekaSystemHardwareFault";
            expr = ''synoSystemStatus{device="teka"} != 1 or synoPowerStatus{device="teka"} != 1 or synoSystemFanStatus{device="teka"} != 1'';
            "for" = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "Synology NAS hardware/fan/power fault on {{ $labels.device }}";
              description = "teka chassis health sensor reported abnormal status ({{ $value }}) for 5m.";
            };
          }
          {
            alert = "TekaVolumeSpaceWarning";
            expr = ''(synoRaidFreeSizeBytes{device="teka"} / synoRaidTotalSizeBytes{device="teka"}) < 0.20'';
            "for" = "15m";
            labels.severity = "warning";
            annotations = {
              summary = "Synology pool below 20% free on {{ $labels.device }}: {{ $labels.raidName }}";
              description = "teka {{ $labels.raidName }} has dropped below 20% available space.";
            };
          }
          {
            alert = "TekaVolumeSpaceCritical";
            expr = ''(synoRaidFreeSizeBytes{device="teka"} / synoRaidTotalSizeBytes{device="teka"}) < 0.10'';
            "for" = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "Synology pool CRITICAL (<10% free) on {{ $labels.device }}: {{ $labels.raidName }}";
              description = "teka {{ $labels.raidName }} has dropped below 10% available space.";
            };
          }
          {
            alert = "TamatoaUplinkDown";
            expr = ''ifAdminStatus{device="tamatoa",ifAlias=~"chief-tui-lan-standby|wan-quantum-nid|chief-tui-opn-wan-igc1|ruckus_basement|ruckus_loft|vivint_recorder|tala-40\\.10|maui-40\\.3|teka-synology-40\\.4|chief-tui-opn-lan-10g"} == 1 and ifOperStatus{device="tamatoa",ifAlias=~"chief-tui-lan-standby|wan-quantum-nid|chief-tui-opn-wan-igc1|ruckus_basement|ruckus_loft|vivint_recorder|tala-40\\.10|maui-40\\.3|teka-synology-40\\.4|chief-tui-opn-lan-10g"} != 1'';
            "for" = "3m";
            labels.severity = "critical";
            annotations = {
              summary = "Core switch uplink down on {{ $labels.device }}: {{ $labels.ifDescr }} ({{ $labels.ifAlias }})";
              description = "tamatoa active infrastructure port {{ $labels.ifDescr }} ({{ $labels.ifAlias }}) is admin-up but operationally down for 3m.";
            };
          }
          {
            alert = "TamatoaInterfaceErrors";
            expr = ''(rate(ifInErrors{device="tamatoa"}[5m]) + rate(ifOutErrors{device="tamatoa"}[5m])) > 0.1'';
            "for" = "10m";
            labels.severity = "warning";
            annotations = {
              summary = "Elevated switch port errors on {{ $labels.device }}: {{ $labels.ifDescr }} ({{ $labels.ifAlias }})";
              description = "tamatoa interface {{ $labels.ifDescr }} sustained >0.1 errors/sec over 10m.";
            };
          }
        ];
      }
    ];
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root -"
    "L+ ${textfileDir}/fleet_inventory.prom - - - - ${fleetInventoryProm}"
  ];

  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9100;
    enabledCollectors = [
      "logind"
      "os"
      "systemd"
      "processes"
      "textfile"
    ];
    extraFlags = [
      "--collector.textfile.directory=${textfileDir}"
    ];
  };

  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9115;
    configFile = blackboxConfigFile;
  };

  systemd.services.maui-storage-metrics = {
    description = "Collect SMART, Btrfs, and ACME cert metrics for Prometheus node_exporter";
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${mauiStorageMetrics}/bin/maui-storage-metrics";
    };
  };

  systemd.timers.maui-storage-metrics = {
    description = "Periodic SMART, Btrfs, and ACME cert metrics collection on maui";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "5m";
      AccuracySec = "30s";
    };
  };

  systemd.services.maui-external-probe = {
    description = "Probe external Cloudflare HTTPS services bypassing internal split-DNS";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStart = "${mauiExternalProbe}/bin/maui-external-probe";
    };
  };

  systemd.timers.maui-external-probe = {
    description = "Periodic public Cloudflare HTTPS probe on maui";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "60s";
      AccuracySec = "10s";
    };
  };

  systemd.services.maui-fleet-versions = {
    description = "Push live Prometheus/SNMP fleet version posture from maui to tala netwatch";
    after = [
      "prometheus.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      LoadCredential = "fleet_env:${config.sops.secrets.fleet_reporter_env.path}";
      ExecStart = "${mauiFleetVersions}/bin/maui-fleet-versions";
    };
  };

  systemd.timers.maui-fleet-versions = {
    description = "Periodic fleet version posture report from maui to tala netwatch";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "6h";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
  };

  services.prometheus.alertmanager = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9093;
    environmentFile = config.sops.secrets.alertmanager_env.path;
    configuration = {
      global = {
        resolve_timeout = "5m";
        smtp_smarthost = "smtp.mx.cloudflare.net:465";
        smtp_from = "faragao.net alertmanager <ops@alerts.faragao.net>";
        smtp_auth_username = "api_token";
        smtp_auth_password = "$ALERTMANAGER_SMTP_PASS";
        smtp_require_tls = false;
      };
      route = {
        receiver = "andre-email";
        group_by = [
          "alertname"
          "device"
          "job"
        ];
        group_wait = "30s";
        group_interval = "5m";
        repeat_interval = "12h";
      };
      inhibit_rules = [
        {
          source_matchers = [ "alertname = HostUnreachable" ];
          target_matchers = [ ''alertname =~ "EndpointProbeFailed|TargetDown"'' ];
          equal = [ "device" ];
        }
        {
          source_matchers = [ "alertname = DiskSpaceCritical" ];
          target_matchers = [ "alertname = DiskSpaceWarning" ];
          equal = [
            "device"
            "mountpoint"
          ];
        }
        {
          source_matchers = [ "alertname = TLSCertExpiringCritical" ];
          target_matchers = [ "alertname = TLSCertExpiringSoon" ];
          equal = [
            "device"
            "instance"
            "cert"
          ];
        }
        {
          source_matchers = [ "alertname = TekaVolumeSpaceCritical" ];
          target_matchers = [ "alertname = TekaVolumeSpaceWarning" ];
          equal = [
            "device"
            "raidName"
          ];
        }
      ];
      receivers = [
        {
          name = "andre-email";
          email_configs = [
            {
              to = "andrearag@gmail.com, andre-a-o-aragao@proton.me";
              force_implicit_tls = true;
              send_resolved = true;
              headers = {
                Subject = "[faragao {{ .Status | toUpper }}] {{ .CommonLabels.alertname }} ({{ if .CommonLabels.device }}{{ .CommonLabels.device }}{{ else }}fleet{{ end }})";
              };
            }
          ];
        }
      ];
    };
  };

  # https://wiki.nixos.org/wiki/Prometheus
  # https://nixos.org/manual/nixos/stable/#module-services-prometheus-exporters-configuration
  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    globalConfig = {
      scrape_interval = "30s";
      evaluation_interval = "30s";
    };
    retentionTime = "30d";
    extraFlags = [ "--storage.tsdb.retention.size=10GB" ];
    alertmanagers = [
      {
        static_configs = [
          { targets = [ "127.0.0.1:9093" ]; }
        ];
      }
    ];
    ruleFiles = [ prometheusRulesFile ];
    scrapeConfigs = [
      {
        job_name = "node";
        scrape_interval = "10s";
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
            labels = {
              device = "maui";
              role = "server";
            };
          }
        ];
      }
      {
        job_name = "node_remote";
        scrape_interval = "30s";
        static_configs = [
          {
            targets = [ "192.168.40.10:9100" ];
            labels = {
              device = "tala";
              role = "server";
            };
          }
        ];
      }
      {
        job_name = "netwatch";
        scrape_interval = "30s";
        static_configs = [
          {
            targets = [ "192.168.40.10:9400" ];
            labels = {
              device = "tala";
              role = "server";
            };
          }
        ];
      }
      {
        job_name = "prometheus";
        scrape_interval = "30s";
        static_configs = [
          {
            targets = [ "127.0.0.1:9090" ];
            labels = {
              device = "maui";
              role = "server";
            };
          }
        ];
      }
      {
        job_name = "alertmanager";
        scrape_interval = "30s";
        static_configs = [
          {
            targets = [ "127.0.0.1:9093" ];
            labels = {
              device = "maui";
              role = "server";
            };
          }
        ];
      }
      {
        job_name = "blackbox_icmp";
        scrape_interval = "60s";
        metrics_path = "/probe";
        params.module = [ "icmp_ipv4" ];
        static_configs = [
          {
            targets = [ "192.168.40.10" ];
            labels = {
              device = "tala";
              role = "server";
            };
          }
          {
            targets = [ "192.168.40.4" ];
            labels = {
              device = "teka";
              role = "nas";
            };
          }
          {
            targets = [ "192.168.100.1" ];
            labels = {
              device = "tamatoa";
              role = "switch";
            };
          }
          {
            targets = [ "192.168.100.2" ];
            labels = {
              device = "chief-tui-opn";
              role = "firewall";
            };
          }
          {
            targets = [ "192.168.100.3" ];
            labels = {
              device = "chief-tui";
              role = "standby-router";
            };
          }
          {
            targets = [ "192.168.100.51" ];
            labels = {
              device = "ruckus-basement";
              role = "ap-member";
            };
          }
          {
            targets = [ "192.168.100.53" ];
            labels = {
              device = "ruckus-secondfloor";
              role = "ap-controller";
            };
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:9115";
          }
        ];
      }
      {
        job_name = "blackbox_http_internal";
        scrape_interval = "60s";
        metrics_path = "/probe";
        static_configs = [
          {
            targets = [ "https://127.0.0.1/api/health" ];
            labels = {
              virtual_host = "monitoring.faragao.net";
              device = "maui";
              service = "grafana";
              role = "server";
              module = "http_2xx";
            };
          }
          {
            targets = [ "https://127.0.0.1/alive" ];
            labels = {
              virtual_host = "vw.faragao.net";
              device = "maui";
              service = "vaultwarden";
              role = "server";
              module = "http_2xx";
            };
          }
          {
            targets = [ "https://127.0.0.1/_matrix/client/versions" ];
            labels = {
              virtual_host = "matrix.faragao.net";
              device = "maui";
              service = "matrix";
              role = "server";
              module = "http_2xx";
            };
          }
          {
            targets = [ "https://127.0.0.1/admin/login.jsp" ];
            labels = {
              virtual_host = "wifi.faragao.net";
              device = "ruckus-secondfloor";
              service = "ruckus-ui";
              role = "ap-controller";
              module = "http_2xx_ruckus";
            };
          }
          {
            targets = [ "https://127.0.0.1/" ];
            labels = {
              virtual_host = "printer.faragao.net";
              device = "maui";
              service = "officejet-proxy";
              role = "server";
              module = "http_2xx";
            };
          }
          {
            targets = [ "https://127.0.0.1/" ];
            labels = {
              virtual_host = "teka-web.faragao.net";
              device = "teka";
              service = "teka-dsm-proxy";
              role = "nas";
              module = "http_2xx";
            };
          }
          {
            targets = [ "https://127.0.0.1/" ];
            labels = {
              virtual_host = "chief-tui-mgmt.faragao.net";
              device = "chief-tui";
              service = "standby-gui-proxy";
              role = "standby-router";
              module = "http_2xx";
            };
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "virtual_host" ];
            target_label = "__param_hostname";
          }
          {
            source_labels = [ "module" ];
            target_label = "__param_module";
          }
          {
            source_labels = [ "virtual_host" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:9115";
          }
        ];
      }
      {
        job_name = "blackbox_tcp";
        scrape_interval = "60s";
        metrics_path = "/probe";
        params.module = [ "tcp_connect" ];
        static_configs = [
          {
            targets = [ "192.168.100.1:22" ];
            labels = {
              device = "tamatoa";
              role = "switch";
              service = "ssh";
            };
          }
          {
            targets = [ "192.168.100.2:53" ];
            labels = {
              device = "chief-tui-opn";
              role = "firewall";
              service = "dns-tcp";
            };
          }
          {
            targets = [ "192.168.40.4:5001" ];
            labels = {
              device = "teka";
              role = "nas";
              service = "dsm-https";
            };
          }
          {
            targets = [ "192.168.100.51:443" ];
            labels = {
              device = "ruckus-basement";
              role = "ap-member";
              service = "ap-https";
            };
          }
          {
            targets = [ "192.168.100.53:443" ];
            labels = {
              device = "ruckus-secondfloor";
              role = "ap-controller";
              service = "ap-https";
            };
          }
          {
            targets = [ "192.168.100.3:443" ];
            labels = {
              device = "chief-tui";
              role = "standby-router";
              service = "standby-gui";
            };
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:9115";
          }
        ];
      }
      {
        job_name = "blackbox_dns";
        scrape_interval = "60s";
        metrics_path = "/probe";
        static_configs = [
          {
            targets = [ "192.168.100.2:53" ];
            labels = {
              module = "dns_internal";
              device = "chief-tui-opn";
              role = "firewall";
              check = "internal-override";
              instance_name = "192.168.100.2:53/internal";
            };
          }
          {
            targets = [ "192.168.100.2:53" ];
            labels = {
              module = "dns_recursive";
              device = "chief-tui-opn";
              role = "firewall";
              check = "recursive-example";
              instance_name = "192.168.100.2:53/recursive";
            };
          }
          {
            targets = [ "192.168.100.3:53" ];
            labels = {
              module = "dns_internal";
              device = "chief-tui";
              role = "standby-router";
              check = "standby-recovery-dns";
              instance_name = "192.168.100.3:53/internal";
            };
          }
          {
            targets = [ "1.1.1.1:53" ];
            labels = {
              module = "dns_public_vw";
              device = "chief-tui-opn";
              role = "wan-dns";
              check = "public-vw-cloudflare";
              instance_name = "1.1.1.1:53/public-vw";
            };
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "module" ];
            target_label = "__param_module";
          }
          {
            source_labels = [ "instance_name" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:9115";
          }
        ];
      }
      {
        job_name = "snmp_tamatoa";
        scrape_interval = "60s";
        scrape_timeout = "20s";
        metrics_path = "/snmp";
        params = {
          module = [ "brocade_if_mib" ];
          auth = [ "tamatoa_v3" ];
        };
        static_configs = [
          {
            targets = [ "192.168.100.1" ];
            labels = {
              device = "tamatoa";
              role = "switch";
            };
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:9116";
          }
        ];
      }
      {
        job_name = "snmp_teka";
        scrape_interval = "60s";
        scrape_timeout = "20s";
        metrics_path = "/snmp";
        params = {
          module = [ "synology" ];
          auth = [ "teka_v3" ];
        };
        static_configs = [
          {
            targets = [ "192.168.40.4" ];
            labels = {
              device = "teka";
              role = "nas";
            };
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:9116";
          }
        ];
      }
    ];
  };

  services.grafana = {
    enable = true;
    settings.server.domain = "monitoring.faragao.net";
    settings.server.http_port = 2342;
    settings.server.http_addr = "127.0.0.1";
    settings.security.secret_key = "$__file{${config.sops.secrets.grafana_secret_key.path}}";
    settings."auth.anonymous".enabled = false;
    settings.users.allow_sign_up = false;

    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Prometheus (faragao)";
          uid = "faragao-prometheus";
          type = "prometheus";
          access = "proxy";
          url = "http://127.0.0.1:9090";
          editable = false;
        }
      ];
      dashboards.settings.providers = [
        {
          name = "faragao-fleet";
          orgId = 1;
          folder = "faragao.net";
          type = "file";
          disableDeletion = true;
          editable = false;
          options.path = ./dashboards;
        }
      ];
    };
  };

  systemd.services.grafana = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
  };

  services.nginx.virtualHosts.${config.services.grafana.settings.server.domain} = {
    forceSSL = true;
    useACMEHost = "faragao.net";
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.grafana.settings.server.http_port}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      extraConfig = ''
        allow 127.0.0.1;
        allow 192.168.10.0/24;
        allow 192.168.50.0/24;
        deny all;
      '';
    };
  };
}
