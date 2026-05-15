#!/usr/bin/env bash
set -euo pipefail

# watch-rebuild.sh
#
# Interactive file watcher that runs `nixos-rebuild switch` after edits
# settle. Intended to live in an open terminal pane while you iterate on
# the flake.
#
# Usage:
#   ./scripts/watch-rebuild.sh             # watcher runs as you, sudo for rebuild
#   sudo ./scripts/watch-rebuild.sh        # watcher itself runs as root
#
# When invoked as a normal user, the script relies on the existing
# passwordless `nixos-rebuild` sudoers rule (system/users.nix) and primes
# sudo once at startup so subsequent rebuilds don't prompt mid-loop.
#
# Watches *.nix files and machines.toml under the repo. After the first
# event, it keeps absorbing events until DEBOUNCE_SECS (default 2) elapse
# with no activity, then triggers one rebuild for the host.
#
# Stop with Ctrl-C. Don't run this concurrently with another manual
# `nixos-rebuild`; both will fight over the same transient activation
# unit.
#
# Caveats (see also feedback_auto_rebuild_race in agent memory):
#  - Every editor save eventually triggers a real activation. Uncommitted
#    work in the tree WILL be applied — flake builds use the working
#    copy, not HEAD.
#  - Don't leave it running while a system.autoUpgrade timer might fire.
#  - The flake.lock file is intentionally NOT watched, so background
#    updates from the auto-flake-update timer don't trigger rebuilds.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBOUNCE_SECS="${DEBOUNCE_SECS:-2}"
HOST="$(hostname)"
PATTERN='.*(\.nix|machines\.toml)$'

cd "$REPO_DIR"

if ! command -v inotifywait >/dev/null; then
  echo "watch-rebuild: inotifywait not on PATH; install pkgs.inotify-tools" >&2
  exit 1
fi

# Use sudo only when we're not already root. Lets the same script work
# under both `./watch-rebuild.sh` and `sudo ./watch-rebuild.sh`.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo --non-interactive)
fi

log() {
  printf '\033[1;34m[watch-rebuild %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"
}

rebuild() {
  log "rebuilding .#${HOST}"
  if "${SUDO[@]}" nixos-rebuild switch --flake ".#${HOST}"; then
    log "rebuild succeeded"
  else
    log "rebuild failed — still watching, fix and save again"
  fi
}

# Prime the sudo credential cache up front so the first rebuild after a
# save doesn't stall on a password prompt. No-op when running as root.
# Auth failure here must not abort the script — the user can retype on
# the first real rebuild.
if [ "${#SUDO[@]}" -gt 0 ]; then
  sudo -v || log "sudo prime failed; you may be prompted at first rebuild"
fi

log "watching ${REPO_DIR} (pattern: ${PATTERN}, debounce: ${DEBOUNCE_SECS}s)"
log "rebuilding host: ${HOST}"
log "press Ctrl-C to stop"

# The loop is wrapped so nothing inside — inotifywait hiccups, sudo prompts,
# nixos-rebuild errors, evaluation failures — can knock the watcher out.
while true; do
  if ! inotifywait -r -q -e modify,create,delete,move \
    --include "$PATTERN" "$REPO_DIR" >/dev/null 2>&1; then
    log "inotifywait exited unexpectedly; restarting watch in 1s"
    sleep 1
    continue
  fi

  # Quiet-window debounce: keep waiting until DEBOUNCE_SECS pass with no
  # matching event. `-t` exits non-zero on timeout, which is our cue that
  # the burst is over.
  while inotifywait -r -q -t "$DEBOUNCE_SECS" \
    -e modify,create,delete,move \
    --include "$PATTERN" "$REPO_DIR" >/dev/null 2>&1; do
    :
  done

  rebuild || log "rebuild() returned non-zero; continuing"
done
