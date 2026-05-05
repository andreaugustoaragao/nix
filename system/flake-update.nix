{
  config,
  pkgs,
  lib,
  owner,
  isWorkstation,
  ...
}:

let
  repoPath = "/home/${owner.name}/projects/personal/nix";

  # Run only on workstation for now. Updates flake.lock, commits, and
  # pushes via the user's existing github-personal SSH alias (sops
  # already deploys id_rsa_personal). Hosts that auto-upgrade
  # afterwards build from the new lock — gives "actual" upgrades on
  # the cadence below while keeping every host bit-for-bit
  # reproducible against the same lock.
  flakeUpdate = pkgs.writeShellScript "flake-update" ''
    set -uo pipefail

    REPO="${repoPath}"
    cd "$REPO"

    log() { echo "[$(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H:%M:%S')] $1"; }

    # Bail on dirty working tree — avoid pushing the user's WIP.
    if ! ${pkgs.git}/bin/git diff-index --quiet HEAD --; then
      log "working tree dirty, skipping"
      exit 0
    fi

    # Bail on unpushed local commits — same reason.
    ${pkgs.git}/bin/git fetch origin main || { log "fetch failed"; exit 1; }
    local_head=$(${pkgs.git}/bin/git rev-parse HEAD)
    origin_head=$(${pkgs.git}/bin/git rev-parse origin/main)
    if [ "$local_head" != "$origin_head" ]; then
      log "local diverges from origin/main, skipping"
      exit 0
    fi

    # Snapshot the lock so we can diff after `nix flake update`.
    old_lock=$(${pkgs.coreutils}/bin/mktemp)
    trap 'rm -f "$old_lock"' EXIT
    ${pkgs.coreutils}/bin/cp flake.lock "$old_lock"

    log "running nix flake update"
    ${pkgs.nix}/bin/nix flake update || { log "flake update failed"; exit 1; }

    if ${pkgs.git}/bin/git diff --quiet flake.lock; then
      log "no input changes"
      exit 0
    fi

    diff_text=$(${pkgs.diffutils}/bin/diff -u "$old_lock" flake.lock || true)
    # Truncate (Matrix readers + the Element client don't enjoy walls of
    # diff). Keep enough to tell which inputs moved.
    max=8000
    if (( ''${#diff_text} > max )); then
      diff_text="''${diff_text:0:$max}"$'\n'"...(truncated)"
    fi

    log "committing and pushing flake.lock"
    ${pkgs.git}/bin/git -c user.name="flake-update" -c user.email="flake-update@workstation" \
      commit flake.lock -m "Auto-update flake inputs ($(${pkgs.coreutils}/bin/date -u +%Y-%m-%d))"

    ${pkgs.git}/bin/git push origin HEAD:main || { log "push failed"; exit 1; }

    pushed_rev=$(${pkgs.git}/bin/git rev-parse --short HEAD)
    host=$(${pkgs.nettools}/bin/hostname)

    # Post-success Matrix message. Non-fatal — a Matrix delivery
    # failure must NOT flip the unit to failed (which would itself
    # fire matrix-alert@flake-update and produce noise about a
    # successful push).
    plain_msg="flake.lock updated on $host (commit $pushed_rev):"$'\n\n'"$diff_text"

    token=$(cat "$CREDENTIALS_DIRECTORY/matrix-token")
    room=$(cat "$CREDENTIALS_DIRECTORY/matrix-room")
    txn=$(date +%s%N)

    body=$(${pkgs.jq}/bin/jq -n \
      --arg plain "$plain_msg" \
      --arg host "$host" \
      --arg rev "$pushed_rev" \
      --arg diff "$diff_text" \
      '{
        msgtype: "m.text",
        body: $plain,
        format: "org.matrix.custom.html",
        formatted_body: (
          "flake.lock updated on " + $host + " (commit " + $rev + "):<br><br><pre>"
          + ($diff
             | gsub("&"; "&amp;")
             | gsub("<"; "&lt;")
             | gsub(">"; "&gt;"))
          + "</pre>"
        )
      }')

    ${pkgs.curl}/bin/curl -fsS --retry 3 --max-time 30 -X PUT \
      "https://matrix.faragao.net/_matrix/client/v3/rooms/$room/send/m.room.message/$txn" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body" || log "matrix post failed (non-fatal)"
  '';
in
lib.mkIf isWorkstation {
  systemd.services.flake-update = {
    description = "Update flake.lock and push to origin/main";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.openssh
      pkgs.git
      pkgs.nix
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      User = owner.name;
      Group = "users";
      ExecStart = "${flakeUpdate}";
      LoadCredential = [
        "matrix-token:${config.sops.secrets."matrix/bot_token".path}"
        "matrix-room:${config.sops.secrets."matrix/alert_room_id".path}"
      ];
    };
    onFailure = [ "matrix-alert@flake-update.service" ];
  };

  systemd.timers.flake-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Sun 21:00 — well before any host's auto-upgrade slot, so by
      # the next *-*-1/2 02:00:00 run desktops/laptop pick up the new
      # lock. (Tala's Sun 03:00 slot is BEFORE this; tala will pick
      # up the new lock the following Sunday — fine for now.)
      OnCalendar = "Sun 21:00";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
  };
}
