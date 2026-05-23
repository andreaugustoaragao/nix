#!/usr/bin/env bash
set -euo pipefail

# watch-rebuild.sh
#
# Interactive file watcher that runs `{nixos,darwin}-rebuild switch`
# after edits settle. Intended to live in an open terminal pane while
# you iterate on the flake.
#
# Usage:
#   ./scripts/watch-rebuild.sh             # watcher runs as you, sudo for rebuild
#   sudo ./scripts/watch-rebuild.sh        # watcher itself runs as root
#
# When invoked as a normal user, the script relies on the existing
# passwordless rebuild sudoers rule and primes sudo once at startup so
# subsequent rebuilds don't prompt mid-loop.
#
# Watches declarative config and source files referenced by the flake.
# Debouncing (default 2s) is delegated to watchexec; bursts collapse
# into a single rebuild.
#
# Stop with Ctrl-C. Don't run this concurrently with another manual
# rebuild; both will fight over the same activation.
#
# Caveats (see also feedback_auto_rebuild_race in agent memory):
#  - Every editor save eventually triggers a real activation. Uncommitted
#    work in the tree WILL be applied — flake builds use the working
#    copy, not HEAD.
#  - Don't leave it running while a system.autoUpgrade timer might fire.
#  - flake.lock is excluded below so background flake-update timers
#    don't trigger rebuilds.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBOUNCE_SECS="${DEBOUNCE_SECS:-2}"
HOST="$(hostname -s)"
EXTS="nix,qml,js,ts,json,toml,kdl,conf,css,sh,service,desktop,lua,fish,yaml,yml"

cd "$REPO_DIR"

case "$(uname -s)" in
  Darwin) REBUILD_BIN=darwin-rebuild ;;
  Linux)  REBUILD_BIN=nixos-rebuild ;;
  *)
    echo "watch-rebuild: unsupported platform $(uname -s)" >&2
    exit 1
    ;;
esac

if ! command -v watchexec >/dev/null; then
  echo "watch-rebuild: watchexec not on PATH; install pkgs.watchexec" >&2
  exit 1
fi

if ! command -v "$REBUILD_BIN" >/dev/null; then
  echo "watch-rebuild: $REBUILD_BIN not on PATH" >&2
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

# Prime the sudo credential cache up front so the first rebuild after a
# save doesn't stall on a password prompt. No-op when running as root.
# Auth failure here must not abort the script — the user can retype on
# the first real rebuild.
if [ "${#SUDO[@]}" -gt 0 ]; then
  sudo -v || log "sudo prime failed; you may be prompted at first rebuild"
fi

log "watching ${REPO_DIR} (exts: ${EXTS}, debounce: ${DEBOUNCE_SECS}s)"
log "rebuild: ${SUDO[*]:-}${SUDO[*]:+ }${REBUILD_BIN} switch --flake .#${HOST}"
log "press Ctrl-C to stop"

# --on-busy-update=queue: if changes land mid-rebuild, queue exactly
#   one follow-up rather than killing the in-flight activation.
# --no-vcs-ignore disabled (default honors .gitignore) so generated
#   files in ignored paths don't trigger rebuilds.
# Explicit --ignore below for high-churn paths that used to be untracked
#   (pi-rs .bench-* scratch dirs) — keeps watchexec's event channel from
#   overflowing during cargo builds. See watchexec#920.
# flake.lock is excluded explicitly so the auto-flake-update timer
#   doesn't kick off interactive rebuilds.
exec watchexec \
  --debounce "${DEBOUNCE_SECS}s" \
  --exts "$EXTS" \
  --ignore flake.lock \
  --ignore '**/target/**' \
  --ignore '**/.bench-*/**' \
  --on-busy-update=queue \
  -- "${SUDO[@]}" "$REBUILD_BIN" switch --flake ".#${HOST}"
