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

    log "running nix flake update"
    ${pkgs.nix}/bin/nix flake update || { log "flake update failed"; exit 1; }

    if ${pkgs.git}/bin/git diff --quiet flake.lock; then
      log "no input changes"
      exit 0
    fi

    log "committing and pushing flake.lock"
    ${pkgs.git}/bin/git -c user.name="flake-update" -c user.email="flake-update@workstation" \
      commit flake.lock -m "Auto-update flake inputs ($(${pkgs.coreutils}/bin/date -u +%Y-%m-%d))"

    ${pkgs.git}/bin/git push origin HEAD:main
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
