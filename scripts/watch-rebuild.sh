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

# Internal re-entry: when watchexec fires, it re-execs this same script
# with --__exec <cmd...> so the interactive shell wrapper only ever sees
# a short `[Running: watch-rebuild.sh --__exec ...]` banner rather than
# an inline `bash -c '<multi-line script>'` dump. Self-recursion keeps
# everything in one file.
#
# sops-nix's `sops-install-secrets` logs every imported host key on
# both build and activation, which floods the rebuild pane with
# fingerprint lines that don't tell the user anything actionable.
# Collapse each contiguous run of `Imported …` lines into a single
# "activating sops..." header. Non-Imported sops output (errors,
# warnings) is left untouched so real failures still surface.
if [ "${1:-}" = "--__exec" ]; then
  shift
  set -o pipefail
  "$@" 2>&1 | awk '
    /^sops-install-secrets: Imported / {
      if (!in_sops) { print "activating sops..."; fflush(); in_sops = 1 }
      next
    }
    { in_sops = 0; print; fflush() }
  '
  rc=$?
  ts=$(date "+%Y-%m-%d %H:%M:%S")
  if [ "$rc" -eq 0 ]; then
    printf "\033[1;32m[watch-rebuild %s] rebuild OK\033[0m\n" "$ts"
  else
    printf "\033[1;31m[watch-rebuild %s] rebuild FAILED (exit %d)\033[0m\n" "$ts" "$rc"
  fi
  exit "$rc"
fi

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
# --ignore <pattern>: keeps high-churn paths under watched dirs from
#   overflowing watchexec's event channel during cargo builds (see
#   watchexec#920). flake.lock is NOT watched, so the auto-flake-update
#   timer can't kick off interactive rebuilds.
# The --__exec re-entry above records each rebuild's exit status and
# prints a timestamped result line so the pane keeps visible history of
# when the last attempt ran and whether it succeeded.
#
# Why explicit --watch instead of recursive on cwd: the repo root holds
# a `result` symlink (output of `nix build`) pointing into /nix/store.
# Watchexec's recursive scan follows symlinks unconditionally, then
# trips on read-only paths like `result/etc/cups/ssl` and emits
# "Native fs watcher error" on stderr — which the interactive shell
# wrapper amplifies into "[[Error (not fatal)]]" banners. Listing
# source roots explicitly avoids the symlink entirely. Keep this list
# in sync if a new top-level source dir is added to the flake.
exec watchexec \
  --quiet \
  --debounce "${DEBOUNCE_SECS}s" \
  --exts "$EXTS" \
  --watch home \
  --watch system \
  --watch hardware \
  --watch darwin \
  --watch secrets \
  --watch assets \
  --watch scripts \
  --watch flake.nix \
  --watch machines.toml \
  --watch statix.toml \
  --ignore '**/target/**' \
  --ignore '**/.bench-*/**' \
  --on-busy-update=queue \
  --shell=none \
  -- "${BASH_SOURCE[0]}" --__exec "${SUDO[@]}" "$REBUILD_BIN" switch \
    --flake ".#${HOST}" \
    --option warn-dirty false
