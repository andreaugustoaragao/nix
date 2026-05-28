{
  pkgs,
  hostName,
  owner,
  ...
}:

# macOS counterpart to system/auto-upgrade.nix (NixOS). Wraps
# `darwin-rebuild` in a self-healing chain — build, switch, rollback
# on activation failure — driven by a root-level launchd daemon, with
# both desktop notifications and Matrix room alerts.
#
# Why a custom launchd job rather than a nix-darwin module: nix-darwin
# does NOT ship a `system.autoUpgrade` equivalent the way NixOS does,
# so the equivalent has to be assembled from launchd primitives.

let
  flakeUrl = "github:andreaugustoaragao/nix";
  logFile = "/var/log/darwin-auto-upgrade.log";
  lockDir = "/var/run/darwin-auto-upgrade.lock.d";

  # Path to the activated darwin-rebuild — stable across rebuilds.
  darwinRebuild = "/run/current-system/sw/bin/darwin-rebuild";

  # Two thresholds from the Linux side carried over verbatim:
  #   - matrix message body truncation cap (Element rendering goes
  #     unreadable past ~10KB)
  matrixMaxBytes = 8000;

  upgradeScript = pkgs.writeShellApplication {
    name = "darwin-auto-upgrade";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.nvd
      pkgs.gnugrep
    ];
    text = ''
      LOG="${logFile}"
      LOCK="${lockDir}"
      HOST="${hostName}"
      FLAKE="${flakeUrl}"
      USER_NAME="${owner.name}"

      log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG" >&2; }

      # mkdir-as-mutex: atomic on any POSIX FS, no flock needed (and
      # macOS BSD userland has no flock(1)). Trap on EXIT so a crashed
      # run still releases the lock.
      if ! mkdir "$LOCK" 2>/dev/null; then
        log "another upgrade run already in progress (lock $LOCK held), skipping"
        exit 0
      fi
      trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

      # Desktop notification — launchd daemons run as root, so we have
      # to cross into the active GUI user's session via `launchctl
      # asuser <uid>` for the notification to actually appear in their
      # notification center. Failures here are non-fatal: if no user
      # is logged in or the session has no display, we still want the
      # upgrade to proceed.
      notify() {
        local title="$1" body="$2" uid
        uid=$(id -u "$USER_NAME" 2>/dev/null || echo 0)
        if [ "$uid" -gt 0 ]; then
          /bin/launchctl asuser "$uid" /usr/bin/osascript \
            -e "on run argv
                  display notification (item 1 of argv) with title (item 2 of argv)
                end run" \
            "$body" "$title" >/dev/null 2>&1 || true
        fi
      }

      # Matrix room post. Reads bot credentials directly from
      # /run/secrets/matrix/ (sops-nix decrypts them at activation,
      # root-only readable, see darwin/sops.nix). Non-fatal — a
      # delivery failure must NOT flip the launchd job to failed.
      matrix_post() {
        local plain="$1" html="$2" token room txn body
        token=$(cat /run/secrets/matrix/bot_token 2>/dev/null || true)
        room=$(cat /run/secrets/matrix/alert_room_id 2>/dev/null || true)
        if [ -z "$token" ] || [ -z "$room" ]; then
          log "matrix secrets unavailable, skipping post"
          return 0
        fi
        txn=$(date +%s%N)
        body=$(jq -n --arg plain "$plain" --arg html "$html" '{
          msgtype: "m.text",
          body: $plain,
          format: "org.matrix.custom.html",
          formatted_body: $html
        }')
        curl -fsS --retry 3 --max-time 30 -X PUT \
          "https://matrix.faragao.net/_matrix/client/v3/rooms/$room/send/m.room.message/$txn" \
          -H "Authorization: Bearer $token" \
          -H "Content-Type: application/json" \
          -d "$body" >/dev/null \
          || log "matrix post failed (non-fatal)"
      }

      # `nvd diff` between the two most recent system profiles.
      # Returns the marker string if there is nothing to diff (first
      # run after install, or no generation change). We use a glob +
      # filtered loop rather than `ls | grep` because
      # writeShellApplication enforces shellcheck and rejects SC2010.
      nvd_diff() {
        local prev curr sorted g base num
        local gens=()
        # nullglob makes the loop run zero times when no system-*-link
        # exists yet (fresh install, pre-first-generation).
        shopt -s nullglob
        for g in /nix/var/nix/profiles/system-*-link; do
          base=''${g##*/}
          num=''${base#system-}
          num=''${num%-link}
          if [[ "$num" =~ ^[0-9]+$ ]]; then
            gens+=("$g")
          fi
        done
        shopt -u nullglob
        if [ "''${#gens[@]}" -lt 2 ]; then
          echo "(no previous generation to compare)"
          return
        fi
        sorted=$(printf '%s\n' "''${gens[@]}" | sort -V)
        prev=$(printf '%s\n' "$sorted" | tail -2 | head -1)
        curr=$(printf '%s\n' "$sorted" | tail -1)
        if [ "$prev" = "$curr" ]; then
          echo "(no previous generation to compare)"
        else
          NO_COLOR=1 nvd diff "$prev" "$curr" 2>&1 \
            || echo "(nvd diff failed)"
        fi
      }

      log "auto-upgrade starting for $HOST against $FLAKE"

      # Step 1: build. Catches evaluation errors and broken inputs
      # without touching the running system. tee+pipefail preserves
      # the rebuild's exit status across the log capture.
      set +e
      ${darwinRebuild} build --flake "$FLAKE#$HOST" --refresh 2>&1 | tee -a "$LOG"
      build_status=''${PIPESTATUS[0]}
      set -e
      if [ "$build_status" -ne 0 ]; then
        log "darwin-rebuild build failed (exit $build_status)"
        notify "darwin-rebuild failed" "Build phase errored on $HOST. See $LOG"
        matrix_post \
          "darwin-rebuild build FAILED on $HOST — see $LOG" \
          "darwin-rebuild build <b>FAILED</b> on <b>$HOST</b> — see <code>$LOG</code>"
        exit 1
      fi

      # Step 2: activate. If activation fails — bad LaunchAgent,
      # broken Brewfile, /Applications symlink conflict — attempt a
      # rollback to the previous generation before alerting.
      set +e
      ${darwinRebuild} switch --flake "$FLAKE#$HOST" --refresh 2>&1 | tee -a "$LOG"
      switch_status=''${PIPESTATUS[0]}
      set -e
      if [ "$switch_status" -ne 0 ]; then
        log "darwin-rebuild switch failed (exit $switch_status), attempting rollback"
        notify "darwin-rebuild switch failed" "Rolling back on $HOST"
        set +e
        ${darwinRebuild} rollback 2>&1 | tee -a "$LOG"
        rollback_status=''${PIPESTATUS[0]}
        set -e
        if [ "$rollback_status" -eq 0 ]; then
          log "rollback succeeded"
          notify "darwin-rebuild rolled back" "Activation failed; previous generation restored on $HOST"
          matrix_post \
            "darwin-rebuild switch FAILED on $HOST — rolled back to previous generation. See $LOG" \
            "darwin-rebuild switch <b>FAILED</b> on <b>$HOST</b> — <b>rolled back</b>. See <code>$LOG</code>"
        else
          log "rollback ALSO failed (exit $rollback_status) — manual intervention required"
          notify "ROLLBACK FAILED" "Manual intervention required on $HOST"
          matrix_post \
            "darwin-rebuild switch AND rollback FAILED on $HOST — manual intervention required" \
            "darwin-rebuild switch <b>AND rollback FAILED</b> on <b>$HOST</b> — manual intervention required"
        fi
        exit 1
      fi

      # Step 3: success path. Quiet if the generation did not change —
      # we don't need a daily "nothing happened" notification.
      diff_text=$(nvd_diff)
      if [ "$diff_text" = "(no previous generation to compare)" ]; then
        log "no generation change, exiting quietly"
        exit 0
      fi

      # Truncate the diff for Matrix readers (full text is in $LOG).
      if (( ''${#diff_text} > ${toString matrixMaxBytes} )); then
        diff_text="''${diff_text:0:${toString matrixMaxBytes}}"$'\n'"...(truncated)"
      fi

      # HTML-escape the diff for the formatted_body branch.
      html_diff=$(printf '%s' "$diff_text" \
        | jq -Rrs '. | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")')

      log "auto-upgrade succeeded"
      notify "darwin-rebuild done" "System updated on $HOST"
      matrix_post \
        "darwin-rebuild done on $HOST:"$'\n\n'"$diff_text" \
        "darwin-rebuild done on <b>$HOST</b>:<br><br><pre>$html_diff</pre>"
    '';
  };
in
{
  # Pre-touch the log file so the launchd job's StandardOutPath /
  # StandardErrorPath have a writable target on first activation.
  # Without this the first run dies with "no such file or directory".
  system.activationScripts.darwinAutoUpgradeLog.text = ''
    if [ ! -e "${logFile}" ]; then
      /usr/bin/touch "${logFile}"
      /bin/chmod 0644 "${logFile}"
    fi
  '';

  launchd.daemons.darwin-auto-upgrade = {
    serviceConfig = {
      Label = "org.darwin.auto-upgrade";
      ProgramArguments = [ "${upgradeScript}/bin/darwin-auto-upgrade" ];

      # Daily at 02:00. Linux desktops do every-other-day; launchd
      # supports lists of StartCalendarInterval entries if you want to
      # narrow this to e.g. Sun/Tue/Thu — for a no-op rebuild (no
      # input changes), running daily is ~10s of disk I/O and worth
      # the tighter latency on flake.lock bumps from the workstation.
      StartCalendarInterval = [
        {
          Hour = 2;
          Minute = 0;
        }
      ];

      # Do not fire on launchd reload (= on every darwin-rebuild). The
      # rebuild that loaded this job would otherwise trigger another
      # full rebuild immediately, mid-activation.
      RunAtLoad = false;

      # Launchd default PATH on macOS is `/usr/bin:/bin:/usr/sbin:/sbin`.
      # darwin-rebuild itself needs `nix` on PATH, which lives under
      # the activated system profile. The wrapper script has its own
      # writeShellApplication PATH, but darwin-rebuild's child
      # processes inherit *this* PATH.
      EnvironmentVariables = {
        PATH = "/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };

      StandardOutPath = logFile;
      StandardErrorPath = logFile;
    };
  };
}
