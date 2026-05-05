{
  config,
  pkgs,
  lib,
  owner,
  isServer,
  ...
}:

let
  flakeUrl = "github:andreaugustoaragao/nix";

  # POST a formatted "nixos-upgrade complete" message with an nvd diff
  # of the previous → current system generation to the Matrix alert
  # room. Mirrors maui's upgradeReport (machines/maui/upgrade.nix);
  # only differences are the homeserver URL (matrix.faragao.net) and
  # the credential source (systemd LoadCredential from sops, not bare
  # files under /data/services/matrix/).
  upgradeReport = pkgs.writeShellScript "nixos-upgrade-report" ''
    set -euo pipefail

    gens=$(${pkgs.coreutils}/bin/ls -1 /nix/var/nix/profiles/ \
      | ${pkgs.gnugrep}/bin/grep -E '^system-[0-9]+-link$' \
      | ${pkgs.coreutils}/bin/sort -V \
      | ${pkgs.coreutils}/bin/tail -2)
    prev=$(echo "$gens" | ${pkgs.coreutils}/bin/head -1)
    curr=$(echo "$gens" | ${pkgs.coreutils}/bin/tail -1)

    if [[ -z "$prev" || -z "$curr" || "$prev" == "$curr" ]]; then
      diff_text="(no previous generation to compare)"
    else
      diff_text=$(NO_COLOR=1 ${pkgs.nvd}/bin/nvd diff \
        "/nix/var/nix/profiles/$prev" "/nix/var/nix/profiles/$curr" 2>&1 \
        || echo "(diff failed)")
    fi

    # Matrix message size cap is generous but readers aren't —
    # truncate very long diffs.
    max=8000
    if (( ''${#diff_text} > max )); then
      diff_text="''${diff_text:0:$max}"$'\n'"...(truncated)"
    fi

    host=$(${pkgs.nettools}/bin/hostname)
    plain_msg="nixos-upgrade complete on $host:"$'\n\n'"$diff_text"

    token=$(cat "$CREDENTIALS_DIRECTORY/matrix-token")
    room=$(cat "$CREDENTIALS_DIRECTORY/matrix-room")
    txn=$(date +%s%N)

    # HTML-escape inside jq via gsub so jq fully owns string encoding.
    body=$(${pkgs.jq}/bin/jq -n \
      --arg plain "$plain_msg" \
      --arg host "$host" \
      --arg diff "$diff_text" \
      '{
        msgtype: "m.text",
        body: $plain,
        format: "org.matrix.custom.html",
        formatted_body: (
          "nixos-upgrade complete on " + $host + ":<br><br><pre>"
          + ($diff
             | gsub("&"; "&amp;")
             | gsub("<"; "&lt;")
             | gsub(">"; "&gt;"))
          + "</pre>"
        )
      }')

    exec ${pkgs.curl}/bin/curl -fsS --retry 3 --max-time 30 -X PUT \
      "https://matrix.faragao.net/_matrix/client/v3/rooms/$room/send/m.room.message/$txn" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body"
  '';

  # Compose a libnotify message body from `nvd diff` between the two
  # most recent system generations and send it to the logged-in user
  # via their session DBus. Mirrors the notification helper in
  # system/nix.nix. Failures are non-fatal — the upgrade unit must
  # not flip to "failed" because the desktop session was absent.
  upgradeNotify = pkgs.writeShellScript "nixos-upgrade-notify" ''
    set -uo pipefail

    status="''${1:-success}"

    gens=$(${pkgs.coreutils}/bin/ls -1 /nix/var/nix/profiles/ \
      | ${pkgs.gnugrep}/bin/grep -E '^system-[0-9]+-link$' \
      | ${pkgs.coreutils}/bin/sort -V \
      | ${pkgs.coreutils}/bin/tail -2)
    prev=$(echo "$gens" | ${pkgs.coreutils}/bin/head -1)
    curr=$(echo "$gens" | ${pkgs.coreutils}/bin/tail -1)

    if [[ -z "$prev" || -z "$curr" || "$prev" == "$curr" ]]; then
      diff_text="(no previous generation to compare)"
    else
      diff_text=$(NO_COLOR=1 ${pkgs.nvd}/bin/nvd diff \
        "/nix/var/nix/profiles/$prev" "/nix/var/nix/profiles/$curr" 2>&1 \
        || echo "(diff failed)")
    fi

    # Keep the notification body short — full diff stays in journald.
    summary=$(echo "$diff_text" | ${pkgs.coreutils}/bin/head -20)

    if [[ "$status" == "fail" ]]; then
      title="❌ NixOS Auto-Upgrade Failed"
      urgency="critical"
      body="Check journalctl -u nixos-upgrade"
    else
      title="✅ NixOS Auto-Upgrade Complete"
      urgency="normal"
      body="$summary"
    fi

    user="${owner.name}"
    uid=$(${pkgs.coreutils}/bin/id -u "$user")
    user_bus="unix:path=/run/user/''${uid}/bus"

    if [ -S "/run/user/''${uid}/bus" ]; then
      ${pkgs.util-linux}/bin/runuser -u "$user" -- \
        ${pkgs.coreutils}/bin/env DBUS_SESSION_BUS_ADDRESS="$user_bus" \
        ${pkgs.libnotify}/bin/notify-send \
          --app-name="NixOS Auto-Upgrade" \
          --urgency="$urgency" \
          "$title" "$body" || true
    fi
  '';
in
{
  system.autoUpgrade = {
    enable = true;
    flake = flakeUrl;
    flags = [
      "--refresh"
      "-L"
    ];
    operation = "switch";
    dates = if isServer then "Sun 03:00" else "*-*-1/2 02:00:00";
    randomizedDelaySec = "30min";
    # Servers benefit from missed-run recovery (Persistent=true). Desktops
    # must NOT — past-due slots fire immediately on first activation, and
    # if the working tree has uncommitted changes the auto-upgrade pulls
    # GitHub main and rolls the live system back. (This bit us once.)
    persistent = isServer;
  };

  systemd.services.nixos-upgrade = {
    serviceConfig = {
      LoadCredential = [
        "matrix-token:${config.sops.secrets."matrix/bot_token".path}"
        "matrix-room:${config.sops.secrets."matrix/alert_room_id".path}"
      ];
      # Both hooks are prefixed with "-" so a Matrix or libnotify
      # delivery failure doesn't flip the unit to failed (which would
      # then itself fire matrix-alert@nixos-upgrade and loop).
      ExecStartPost = [ "-${upgradeReport}" ] ++ lib.optional (!isServer) "-${upgradeNotify} success";
    };
    onFailure = [
      "matrix-alert@nixos-upgrade.service"
    ]
    ++ lib.optional (!isServer) "nixos-upgrade-notify-fail.service";
  };

  systemd.services.nixos-upgrade-notify-fail = lib.mkIf (!isServer) {
    description = "Desktop notification on nixos-upgrade failure";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${upgradeNotify} fail";
    };
  };
}
