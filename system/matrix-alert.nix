{
  config,
  pkgs,
  ...
}:

let
  # POST a one-line "alert" to the Matrix room. Used as the OnFailure
  # handler for any service whose failure should land in the alert
  # room (mirrors maui's matrix-alert@ template). Differences vs maui:
  #   - Goes through https://matrix.faragao.net (Cloudflare → maui's
  #     nginx → continuwuity) since the homeserver isn't local here.
  #     Internal LAN clients still resolve the same name to maui's
  #     192.168.40.3 via maui's unbound, so this works on/off-LAN.
  #   - Credentials come from sops via systemd LoadCredential, not
  #     from bare files under /data/services/matrix/.
  matrixAlert = pkgs.writeShellScript "matrix-alert" ''
    set -euo pipefail

    unit="''${1:-unknown}"
    host=$(${pkgs.nettools}/bin/hostname)
    msg="$unit failed on $host"

    token=$(cat "$CREDENTIALS_DIRECTORY/matrix-token")
    room=$(cat "$CREDENTIALS_DIRECTORY/matrix-room")
    txn=$(date +%s%N)

    body=$(${pkgs.jq}/bin/jq -n --arg body "$msg" '{msgtype:"m.text",body:$body}')

    exec ${pkgs.curl}/bin/curl -fsS --retry 3 --max-time 15 -X PUT \
      "https://matrix.faragao.net/_matrix/client/v3/rooms/$room/send/m.room.message/$txn" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body"
  '';

  # Daily sweep: enumerate any units in failed state and post a single
  # message listing them. Catches services that crashed without an
  # OnFailure= alert wired (a real risk: enumerating every unit by
  # hand is sparse). Silent when nothing is failed.
  failedUnitsAlert = pkgs.writeShellScript "failed-units-alert" ''
    set -uo pipefail

    failed=$(${pkgs.systemd}/bin/systemctl --failed --no-legend --no-pager 2>/dev/null \
      | ${pkgs.gawk}/bin/awk '{print $2}' \
      | ${pkgs.coreutils}/bin/paste -sd ', ' -)

    if [ -z "$failed" ]; then
      exit 0
    fi

    host=$(${pkgs.nettools}/bin/hostname)
    msg="failed units on $host: $failed"

    token=$(cat "$CREDENTIALS_DIRECTORY/matrix-token")
    room=$(cat "$CREDENTIALS_DIRECTORY/matrix-room")
    txn=$(date +%s%N)

    body=$(${pkgs.jq}/bin/jq -n --arg body "$msg" '{msgtype:"m.text",body:$body}')

    exec ${pkgs.curl}/bin/curl -fsS --retry 3 --max-time 15 -X PUT \
      "https://matrix.faragao.net/_matrix/client/v3/rooms/$room/send/m.room.message/$txn" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body"
  '';
in
{
  systemd.services."matrix-alert@" = {
    description = "Post Matrix alert for %i";
    unitConfig.ConditionPathExists = [
      config.sops.secrets."matrix/bot_token".path
      config.sops.secrets."matrix/alert_room_id".path
    ];
    serviceConfig = {
      Type = "oneshot";
      LoadCredential = [
        "matrix-token:${config.sops.secrets."matrix/bot_token".path}"
        "matrix-room:${config.sops.secrets."matrix/alert_room_id".path}"
      ];
      ExecStart = "${matrixAlert} %i";
    };
  };

  systemd.services.failed-units-alert = {
    description = "Sweep systemctl --failed and post non-empty list to Matrix";
    unitConfig.ConditionPathExists = [
      config.sops.secrets."matrix/bot_token".path
      config.sops.secrets."matrix/alert_room_id".path
    ];
    serviceConfig = {
      Type = "oneshot";
      LoadCredential = [
        "matrix-token:${config.sops.secrets."matrix/bot_token".path}"
        "matrix-room:${config.sops.secrets."matrix/alert_room_id".path}"
      ];
      ExecStart = "${failedUnitsAlert}";
    };
  };

  systemd.timers.failed-units-alert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
  };
}
