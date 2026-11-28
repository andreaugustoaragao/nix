{ config, pkgs, ... }:
let
  secretPaths = [
    config.sops.secrets.adm_password.path
    config.sops.secrets.root_password.path
    config.sops.secrets.grafana_secret_key.path
    config.sops.secrets.vaultwarden_env.path
    config.sops.secrets.acme_cloudflare_env.path
    config.sops.secrets.matrix_bot_token.path
    config.sops.secrets.matrix_alert_room_id.path
    config.sops.secrets.healthchecks_upgrade_url.path
    config.sops.secrets.nginx_origin_cert.path
    config.sops.secrets.nginx_origin_key.path
    config.sops.secrets.alertmanager_env.path
    config.sops.secrets.snmp_exporter_env.path
    config.sops.secrets.fleet_reporter_env.path
  ];

  mauiVerify = pkgs.writeShellApplication {
    name = "maui-verify";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gawk
      pkgs.getent
      pkgs.gnugrep
      pkgs.jq
      pkgs.samba
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      set -euo pipefail

      services=(
        continuwuity
        vaultwarden
        grafana
        prometheus
        alertmanager
        prometheus-blackbox-exporter
        prometheus-snmp-exporter
        samba-smbd
        nginx
        sshd
        prometheus-node-exporter
      )

      for name in "''${services[@]}"; do
        systemctl is-active --quiet "$name"
        printf 'PASS service %s\n' "$name"
      done

      mountpoint --quiet /data
      printf 'PASS mount /data\n'

      [[ -d /run/secrets ]]
      [[ -d /run/secrets-for-users ]]
      if (( EUID == 0 )); then
        for secret_file in ${builtins.concatStringsSep " " secretPaths}; do
          [[ -s "$secret_file" ]] || {
            printf 'FAIL missing or empty secret: %s\n' "$secret_file" >&2
            exit 1
          }
        done
        printf 'PASS sops secrets (%d decrypted files verified)\n' "${toString (builtins.length secretPaths)}"
      else
        printf 'PASS sops secrets dirs present (run as root to verify individual 0400 files)\n'
      fi

      grep -Eq '^nameserver 192\.168\.100\.2$' /etc/resolv.conf
      if grep -Eq '^nameserver 127\.0\.0\.1$' /etc/resolv.conf; then
        printf 'FAIL unexpected 127.0.0.1 nameserver in /etc/resolv.conf\n' >&2
        exit 1
      fi
      printf 'PASS /etc/resolv.conf uses 192.168.100.2 (no 127.0.0.1)\n'

      local_records=$(getent ahostsv4 matrix.faragao.net)
      awk '{print $1}' <<<"$local_records" | grep -Fxq '192.168.40.3'
      printf 'PASS host DNS matrix.faragao.net -> 192.168.40.3\n'

      ext_records=$(getent ahostsv4 example.com)
      ext_ip=$(awk 'NR == 1 { print $1 }' <<<"$ext_records")
      [[ -n "$ext_ip" ]]
      printf 'PASS host DNS example.com -> %s\n' "$ext_ip"

      curl -fsS --max-time 20 http://127.0.0.1:6167/_matrix/client/versions | jq -e '.versions | length > 0' >/dev/null
      curl -fsS --max-time 20 http://127.0.0.1:8000/alive >/dev/null
      curl -fsS --max-time 20 http://127.0.0.1:2342/api/health | jq -e '.database == "ok"' >/dev/null
      curl -fsS --max-time 20 http://127.0.0.1:9090/-/ready >/dev/null
      curl -fsS --max-time 20 http://127.0.0.1:9093/-/ready >/dev/null
      curl -fsS --max-time 20 http://127.0.0.1:9116/metrics >/dev/null
      curl -fsS --max-time 20 http://127.0.0.1:9090/api/v1/targets | jq -e '
        .status == "success" and (.data.activeTargets | length > 0)
        and all(.data.activeTargets[]; .health == "up")' >/dev/null
      printf 'PASS Matrix, Vaultwarden, Grafana, Prometheus, Alertmanager, SNMP exporter, and scrape targets\n'

      smb_out=$(smbclient -L 127.0.0.1 -N -g 2>/dev/null || true)
      grep -Eq '^Disk\|timemachine\|' <<<"$smb_out"
      printf 'PASS Samba timemachine share discovery\n'

      for target in \
        "matrix.faragao.net/_matrix/client/versions" \
        "vw.faragao.net/alive" \
        "monitoring.faragao.net/api/health"; do
        host="''${target%%/*}"
        curl -fsS --max-time 20 --resolve "$host:443:127.0.0.1" "https://$target" >/dev/null
        printf 'PASS HTTPS %s\n' "$host"
      done

      printf 'MAUI_VERIFY_OK\n'
    '';
  };
in
{
  environment.systemPackages = [ mauiVerify ];
}
