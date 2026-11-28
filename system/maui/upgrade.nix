{ config, pkgs, ... }:
let
  hcPing = pkgs.writeShellScript "hc-ping" ''
    url=$(cat "$CREDENTIALS_DIRECTORY/hc-url")
    exec ${pkgs.curl}/bin/curl -fsS --retry 3 --max-time 10 "$url$1"
  '';

  # Posts an `nvd diff` summary of the upgrade to the Matrix alert room.
  # Reads the bot token + room id from sops-nix, hits continuwuity directly
  # on localhost. Non-fatal — failures here don't fail the upgrade unit.
  upgradeReport = pkgs.writeShellScript "upgrade-report" ''
    set -euo pipefail

    gens=$(ls -1 /nix/var/nix/profiles/ | grep -E '^system-[0-9]+-link$' | sort -V | tail -2)
    prev=$(echo "$gens" | head -1)
    curr=$(echo "$gens" | tail -1)

    if [[ -z "$prev" || -z "$curr" || "$prev" == "$curr" ]]; then
      diff_text="(no previous generation to compare)"
    else
      diff_text=$(NO_COLOR=1 ${pkgs.nvd}/bin/nvd diff "/nix/var/nix/profiles/$prev" "/nix/var/nix/profiles/$curr" 2>&1 || echo "(diff failed)")
    fi

    # Matrix message size cap is generous but readers aren't — truncate
    # very long diffs.
    max=8000
    if (( ''${#diff_text} > max )); then
      diff_text="''${diff_text:0:$max}"$'\n'"...(truncated)"
    fi

    host=$(${pkgs.nettools}/bin/hostname)
    plain_msg="nixos-upgrade complete on $host:"$'\n\n'"$diff_text"

    token=$(cat ${config.sops.secrets.matrix_bot_token.path})
    room=$(cat ${config.sops.secrets.matrix_alert_room_id.path})
    txn=$(date +%s%N)

    # HTML-escape happens inside jq via gsub, so jq fully owns string
    # encoding (avoids the bash-parameter-expansion edge case where
    # earlier attempts produced "gt;" without the leading "&"). Plain
    # <pre> with no <code> — Element's syntax highlighter on <code>
    # blocks was stripping the entities mid-render.
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
      "http://127.0.0.1:6167/_matrix/client/v3/rooms/$room/send/m.room.message/$txn" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body"
  '';
in
{
  # libgit2 (used by nix flake fetchers) refuses to open repos whose
  # top-level dir is owned by a different user than the running process.
  # nixos-upgrade runs as root; the checkout is owned by adm.
  programs.git = {
    enable = true;
    config.safe.directory = "/home/adm/nix";
  };

  system.autoUpgrade = {
    enable = true;
    flake = "github:andreaugustoaragao/nix/main#maui";
    flags = [
      "--refresh"
      "-L"
    ];
    operation = "switch";
    dates = "Sun 03:00";
    randomizedDelaySec = "45min";
    persistent = true;
  };

  systemd.services.nixos-upgrade = {
    serviceConfig = {
      LoadCredential = "hc-url:${config.sops.secrets.healthchecks_upgrade_url.path}";
      ExecStartPre = "-${hcPing} /start";
      ExecStartPost = [
        "-${hcPing}"
        "-${upgradeReport}"
      ];
    };
    onFailure = [
      "hc-ping-fail.service"
      "matrix-alert@nixos-upgrade.service"
    ];
  };

  systemd.services.hc-ping-fail = {
    description = "Ping healthchecks.io on nixos-upgrade failure";
    serviceConfig = {
      Type = "oneshot";
      LoadCredential = "hc-url:${config.sops.secrets.healthchecks_upgrade_url.path}";
      ExecStart = "${hcPing} /fail";
    };
  };
}
