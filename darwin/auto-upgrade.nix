{
  config,
  lib,
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
  # Rotate /var/log/darwin-auto-upgrade.log once it exceeds 2 MiB so the
  # append-only launchd log doesn't grow unbounded.
  logMaxBytes = 2097152;

  upgradeScript = pkgs.writeShellApplication {
    name = "darwin-auto-upgrade";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.nvd
      pkgs.gnugrep
      config.nix.package
    ];
    text = ''
      LOG="${logFile}"
      LOCK="${lockDir}"
      HOST="${hostName}"
      FLAKE="${flakeUrl}"
      USER_NAME="${owner.name}"
      PROFILE="/nix/var/nix/profiles/system"

      # Launchd redirects both StandardOutPath and StandardErrorPath to
      # $LOG (O_APPEND), so write to stderr/stdout directly without `tee`.
      log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2; }

      # Bounded log rotation: copy to $LOG.1 and truncate in place so
      # launchd's open O_APPEND file descriptor stays valid.
      if [ -f "$LOG" ]; then
        log_size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
        if [ "$log_size" -gt ${toString logMaxBytes} ]; then
          cp -f "$LOG" "$LOG.1" 2>/dev/null || true
          : > "$LOG"
        fi
      fi

      # mkdir-as-mutex: atomic on any POSIX FS, no flock needed (and
      # macOS BSD userland has no flock(1)). Trap on EXIT so a crashed
      # run still releases the lock.
      if ! mkdir "$LOCK" 2>/dev/null; then
        log "another upgrade run already in progress (lock $LOCK held), skipping"
        exit 0
      fi
      work_dir=$(mktemp -d /tmp/darwin-auto-upgrade.XXXXXX)
      trap 'rm -rf "$work_dir"; rmdir "$LOCK" 2>/dev/null || true' EXIT
      cd "$work_dir"
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

      # Diff two explicit system profile generations via `nvd diff`.
      nvd_diff() {
        local prev="$1" curr="$2"
        if [ -z "$prev" ] || [ -z "$curr" ] || [ "$prev" = "$curr" ]; then
          echo "(no previous generation to compare)"
          return
        fi
        NO_COLOR=1 nvd diff "$prev" "$curr" 2>&1 \
          || echo "(nvd diff failed)"
      }

      profile_link_path() {
        local target
        target=$(readlink "$PROFILE" 2>/dev/null || true)
        if [ -n "$target" ]; then
          echo "/nix/var/nix/profiles/$target"
        fi
      }

      profile_gen_num() {
        local target
        target=$(readlink "$PROFILE" 2>/dev/null || true)
        if [[ "$target" =~ ^system-([0-9]+)-link$ ]]; then
          echo "''${BASH_REMATCH[1]}"
        fi
      }

      log "auto-upgrade starting for $HOST against $FLAKE"

      # Resolve mutable HEAD once into a content-addressed URL so build
      # and switch operate on the exact same revision.
      set +e
      meta_json=$(nix --extra-experimental-features 'nix-command flakes' \
        flake metadata --json --refresh "$FLAKE")
      meta_status=$?
      set -e
      if [ "$meta_status" -ne 0 ]; then
        log "flake metadata resolution failed (exit $meta_status)"
        notify "darwin-rebuild failed" "Failed to resolve $FLAKE on $HOST. See $LOG"
        matrix_post \
          "darwin-rebuild metadata FAILED on $HOST — see $LOG" \
          "darwin-rebuild metadata <b>FAILED</b> on <b>$HOST</b> — see <code>$LOG</code>"
        exit 1
      fi
      pinned_flake=$(printf '%s' "$meta_json" | jq -r '.url // empty')
      if [ -z "$pinned_flake" ]; then
        log "flake metadata returned empty locked URL"
        exit 1
      fi
      log "pinned revision: $pinned_flake"

      # Step 1: build against the pinned revision. Catches evaluation
      # errors and broken inputs without touching the running system.
      set +e
      ${darwinRebuild} build --flake "$pinned_flake#$HOST"
      build_status=$?
      set -e
      if [ "$build_status" -ne 0 ]; then
        log "darwin-rebuild build failed (exit $build_status)"
        notify "darwin-rebuild failed" "Build phase errored on $HOST. See $LOG"
        matrix_post \
          "darwin-rebuild build FAILED on $HOST — see $LOG" \
          "darwin-rebuild build <b>FAILED</b> on <b>$HOST</b> — see <code>$LOG</code>"
        exit 1
      fi

      # Capture the active generation right before switching so we only
      # roll back if the profile actually advances, and diff the exact
      # before/after generations on success.
      pre_link=$(profile_link_path)
      pre_gen=$(profile_gen_num)

      # Step 2: activate the exact same pinned revision.
      set +e
      ${darwinRebuild} switch --flake "$pinned_flake#$HOST"
      switch_status=$?
      set -e
      post_link=$(profile_link_path)
      if [ "$switch_status" -ne 0 ]; then
        if [ -n "$pre_gen" ] && [ "$post_link" != "$pre_link" ]; then
          log "darwin-rebuild switch failed (exit $switch_status) after advancing profile, rolling back to generation $pre_gen"
          notify "darwin-rebuild switch failed" "Rolling back to generation $pre_gen on $HOST"
          set +e
          ${darwinRebuild} --switch-generation "$pre_gen"
          rollback_status=$?
          set -e
          if [ "$rollback_status" -eq 0 ]; then
            log "rollback to generation $pre_gen succeeded"
            notify "darwin-rebuild rolled back" "Activation failed; generation $pre_gen restored on $HOST"
            matrix_post \
              "darwin-rebuild switch FAILED on $HOST — rolled back to generation $pre_gen. See $LOG" \
              "darwin-rebuild switch <b>FAILED</b> on <b>$HOST</b> — <b>rolled back to generation $pre_gen</b>. See <code>$LOG</code>"
          else
            log "rollback to generation $pre_gen ALSO failed (exit $rollback_status) — manual intervention required"
            notify "ROLLBACK FAILED" "Manual intervention required on $HOST"
            matrix_post \
              "darwin-rebuild switch AND rollback FAILED on $HOST — manual intervention required" \
              "darwin-rebuild switch <b>AND rollback FAILED</b> on <b>$HOST</b> — manual intervention required"
          fi
        else
          log "darwin-rebuild switch failed (exit $switch_status); profile did not advance (still $pre_link), skipping rollback"
          notify "darwin-rebuild switch failed" "Switch errored before profile change on $HOST. See $LOG"
          matrix_post \
            "darwin-rebuild switch FAILED on $HOST (profile unchanged) — see $LOG" \
            "darwin-rebuild switch <b>FAILED</b> on <b>$HOST</b> (profile unchanged) — see <code>$LOG</code>"
        fi
        exit 1
      fi

      # Step 3: success path. Quiet if the generation did not change —
      # we don't need a daily "nothing happened" notification.
      if [ -z "$post_link" ] || [ "$post_link" = "$pre_link" ]; then
        log "no generation change, exiting quietly"
        exit 0
      fi
      diff_text=$(nvd_diff "$pre_link" "$post_link")

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
  # Pre-touch the log file via postActivation (custom activationScripts
  # keys are ignored by nix-darwin) so the launchd job's StandardOutPath /
  # StandardErrorPath have a writable target on first activation.
  system.activationScripts.postActivation.text = lib.mkAfter ''
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
      # Include the corporate CA bundle from darwin/certs.nix so both
      # `nix flake metadata`/`darwin-rebuild` and `curl` (Matrix alerts)
      # trust the Netskope/corp TLS chain under launchd.
      EnvironmentVariables = {
        PATH = "/run/current-system/sw/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        inherit (config.environment.variables)
          SSL_CERT_FILE
          NIX_SSL_CERT_FILE
          GIT_SSL_CAINFO
          CURL_CA_BUNDLE
          ;
      };

      StandardOutPath = logFile;
      StandardErrorPath = logFile;
    };
  };
}
