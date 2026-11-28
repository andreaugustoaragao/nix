{
  lib,
  pkgs,
  hostName,
  ...
}:
let
  textfileDir = "/var/lib/node_exporter/textfile";
  allowedScraperCIDR = "192.168.40.3/32"; # maui only

  talaStorageMetrics = pkgs.writeShellApplication {
    name = "tala-storage-metrics";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      jq
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

      {
        printf '# HELP storage_metrics_timestamp_seconds Unix timestamp of latest storage/SMART collector run.\n'
        printf '# TYPE storage_metrics_timestamp_seconds gauge\n'
        printf 'storage_metrics_timestamp_seconds %s\n' "$now"

        dev="/dev/sda"
        json=""
        if out="$(smartctl -j -i -H -A "$dev" 2>/dev/null || true)" && jq -e '.smart_status.passed != null' <<<"$out" >/dev/null 2>&1; then
          json="$out"
        elif out_sat="$(smartctl -j -i -H -A -d sat "$dev" 2>/dev/null || true)" && jq -e '.smart_status.passed != null' <<<"$out_sat" >/dev/null 2>&1; then
          json="$out_sat"
        elif [[ -n "''${out:-}" ]] && jq -e . <<<"$out" >/dev/null 2>&1; then
          json="$out"
        fi

        model="unknown"
        if [[ -n "$json" ]]; then
          model="$(jq -r '(.model_name // .scsi_model_name // "unknown")' <<<"$json")"
        fi
        dev_lbl="$(prom_label "$dev")"
        model_lbl="$(prom_label "$model")"

        printf '# HELP smart_device_supported Whether SMART health data is readable for this block device.\n'
        printf '# TYPE smart_device_supported gauge\n'
        if [[ -n "$json" ]] && jq -e '.smart_status.passed != null' <<<"$json" >/dev/null 2>&1; then
          printf 'smart_device_supported{device="%s",model="%s"} 1\n' "$dev_lbl" "$model_lbl"

          healthy="$(jq -r 'if .smart_status.passed then 1 else 0 end' <<<"$json")"
          printf '# HELP smart_device_healthy SMART overall health status (1=PASSED, 0=FAILED).\n'
          printf '# TYPE smart_device_healthy gauge\n'
          printf 'smart_device_healthy{device="%s",model="%s"} %s\n' "$dev_lbl" "$model_lbl" "$healthy"

          temp="$(jq -r '.temperature.current // empty' <<<"$json")"
          if [[ -n "$temp" ]]; then
            printf '# HELP smart_device_temperature_celsius Current drive temperature in Celsius.\n'
            printf '# TYPE smart_device_temperature_celsius gauge\n'
            printf 'smart_device_temperature_celsius{device="%s"} %s\n' "$dev_lbl" "$temp"
          fi

          reallocated="$(jq -r '([.ata_smart_attributes.table[]? | select(.id == 5) | .raw.value] | first) // empty' <<<"$json")"
          if [[ -n "$reallocated" ]]; then
            printf '# HELP smart_device_reallocated_sectors ATA attribute 5 reallocated sector count.\n'
            printf '# TYPE smart_device_reallocated_sectors gauge\n'
            printf 'smart_device_reallocated_sectors{device="%s"} %s\n' "$dev_lbl" "$reallocated"
          fi

          pending="$(jq -r '([.ata_smart_attributes.table[]? | select(.id == 197) | .raw.value] | first) // empty' <<<"$json")"
          if [[ -n "$pending" ]]; then
            printf '# HELP smart_device_pending_sectors ATA attribute 197 current pending sector count.\n'
            printf '# TYPE smart_device_pending_sectors gauge\n'
            printf 'smart_device_pending_sectors{device="%s"} %s\n' "$dev_lbl" "$pending"
          fi

          uncorrectable="$(jq -r '([.ata_smart_attributes.table[]? | select(.id == 198) | .raw.value] | first) // empty' <<<"$json")"
          if [[ -n "$uncorrectable" ]]; then
            printf '# HELP smart_device_uncorrectable_sectors ATA attribute 198 offline uncorrectable sector count.\n'
            printf '# TYPE smart_device_uncorrectable_sectors gauge\n'
            printf 'smart_device_uncorrectable_sectors{device="%s"} %s\n' "$dev_lbl" "$uncorrectable"
          fi

          pct_used="$(jq -r '(.nvme_smart_health_information_log.percentage_used // ([.ata_smart_attributes.table[]? | select(.id == 231 and (.name | test("Life_Left|Remain"; "i"))) | (100 - .value)] | first)) // empty' <<<"$json")"
          if [[ -n "$pct_used" ]]; then
            printf '# HELP smart_device_percentage_used Estimated percentage of rated SSD endurance used.\n'
            printf '# TYPE smart_device_percentage_used gauge\n'
            printf 'smart_device_percentage_used{device="%s"} %s\n' "$dev_lbl" "$pct_used"
          fi
        else
          printf 'smart_device_supported{device="%s",model="%s"} 0\n' "$dev_lbl" "$model_lbl"
        fi

        if [[ -d /var/lib/loki ]]; then
          loki_bytes="$(du -sb /var/lib/loki | awk '{print $1}')"
          printf '# HELP loki_storage_bytes Total on-disk bytes under /var/lib/loki.\n'
          printf '# TYPE loki_storage_bytes gauge\n'
          printf 'loki_storage_bytes{path="/var/lib/loki"} %s\n' "$loki_bytes"
        fi
      } > "$tmp"

      chmod 0644 "$tmp"
      mv -f "$tmp" "${textfileDir}/storage.prom"
      trap - EXIT
    '';
  };
in
{
  config = lib.mkIf (hostName == "tala") {
    environment.systemPackages = [ pkgs.smartmontools ];

    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 root root -"
    ];

    services.prometheus.exporters.node = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 9100;
      enabledCollectors = [
        "systemd"
        "processes"
        "textfile"
      ];
      extraFlags = [
        "--collector.textfile.directory=${textfileDir}"
      ];
    };

    systemd.services.tala-storage-metrics = {
      description = "Collect SMART storage metrics for Prometheus node_exporter textfile";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = lib.getExe talaStorageMetrics;
      };
    };

    systemd.timers.tala-storage-metrics = {
      description = "Periodic SMART storage metrics collection on tala";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "5m";
        AccuracySec = "30s";
      };
    };

    networking.firewall.extraCommands = ''
      iptables -w -A nixos-fw -s ${allowedScraperCIDR} -p tcp --dport 9100 -j nixos-fw-accept
    '';

    networking.firewall.extraStopCommands = ''
      iptables -w -D nixos-fw -s ${allowedScraperCIDR} -p tcp --dport 9100 -j nixos-fw-accept 2>/dev/null || true
    '';
  };
}
