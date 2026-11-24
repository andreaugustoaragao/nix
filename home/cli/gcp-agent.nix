{
  pkgs,
  ...
}:
let
  project = "core-optimized-lab";
  zone = "us-west3-a";
  instance = "gcp-aragao-agent-wk";

  wake = pkgs.writeShellApplication {
    name = "gcp-agent-wake";
    runtimeInputs = with pkgs; [
      coreutils
      google-cloud-sdk
      openssh
    ];
    text = ''
      set -euo pipefail

      mode="ssh"
      case "''${1:-}" in
        --no-ssh)
          mode="boot"
          shift
          ;;
        --proxy)
          mode="proxy"
          shift
          ;;
      esac

      log() {
        printf '[%s] %s\n' "${instance}" "$*" >&2
      }

      status="$(gcloud compute instances describe ${instance} \
        --project=${project} \
        --zone=${zone} \
        --format='value(status)' </dev/null)"

      if [ "$status" = "STOPPING" ]; then
        log "Waiting for VM to finish stopping..."
        while [ "$status" = "STOPPING" ]; do
          sleep 3
          status="$(gcloud compute instances describe ${instance} \
            --project=${project} \
            --zone=${zone} \
            --format='value(status)' </dev/null)"
        done
      fi

      if [ "$status" != "RUNNING" ]; then
        log "Starting VM (was $status)..."
        gcloud compute instances start ${instance} \
          --project=${project} \
          --zone=${zone} \
          --quiet </dev/null >&2
      fi

      log "Waiting for SSH over IAP..."
      ready=0
      for _ in $(seq 1 30); do
        if ssh -n -o BatchMode=yes -o ConnectTimeout=5 ${instance} true </dev/null >/dev/null 2>&1; then
          ready=1
          break
        fi
        sleep 2
      done

      if [ "$ready" -ne 1 ]; then
        log "Timed out waiting for SSH on ${instance}."
        exit 1
      fi

      if [ "$mode" != "proxy" ] && command -v hc >/dev/null 2>&1; then
        hc machine login ${instance} </dev/null >/dev/null 2>&1 || true
      fi

      case "$mode" in
        boot)
          log "Ready."
          ;;
        proxy)
          exec gcloud compute start-iap-tunnel ${instance} 22 \
            --listen-on-stdin \
            --project=${project} \
            --zone=${zone} \
            --quiet
          ;;
        ssh)
          exec ssh ${instance} "$@"
          ;;
      esac
    '';
  };
in
{
  home.packages = [ wake ];
}
