#!/usr/bin/env bash
set -euo pipefail

# Build the current host configuration after edits settle. Activation is a
# separate, authenticated command, printed after each successful build.
# Usage: ./scripts/watch-rebuild.sh (as your normal user; Ctrl-C to stop).
# Changes during a build queue one follow-up. flake.lock is not watched.

if [ "$(id -u)" -eq 0 ]; then
  echo "watch-rebuild: run as your normal user; the watcher only builds" >&2
  exit 1
fi
case "${1:-}" in
  ""|--__build) ;;
  *) echo "watch-rebuild: unsupported argument: $1" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "watch-rebuild: additional arguments are not accepted" >&2
  exit 2
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBOUNCE_SECS="${DEBOUNCE_SECS:-2}"
WATCH_HOST="$(hostname -s)"
EXTS="nix,qml,js,ts,json,toml,kdl,conf,css,sh,service,desktop,lua,fish,yaml,yml"
cd "$REPO_DIR"

case "$(uname -s)" in
  Darwin)
    BUILD_ATTR="darwinConfigurations.${WATCH_HOST}.system"
    REBUILD_BIN=darwin-rebuild
    ;;
  Linux)
    BUILD_ATTR="nixosConfigurations.${WATCH_HOST}.config.system.build.toplevel"
    REBUILD_BIN=nixos-rebuild
    ;;
  *) echo "watch-rebuild: unsupported platform $(uname -s)" >&2; exit 1 ;;
esac

if ! command -v nix >/dev/null; then
  echo "watch-rebuild: nix not on PATH" >&2
  exit 1
fi

# Fixed re-entry command: old --__exec sudo ... invocations are rejected.
if [ "${1:-}" = "--__build" ]; then
  rc=0
  nix build ".#${BUILD_ATTR}" --no-link --print-out-paths \
    --option warn-dirty false || rc=$?
  ts=$(date "+%Y-%m-%d %H:%M:%S")
  if [ "$rc" -eq 0 ]; then
    printf "\033[1;32m[watch-rebuild %s] build OK\033[0m\n" "$ts"
    printf 'Activate when ready: sudo %s switch --flake %q\n' \
      "$REBUILD_BIN" "${REPO_DIR}#${WATCH_HOST}"
  else
    printf "\033[1;31m[watch-rebuild %s] build FAILED (exit %d)\033[0m\n" "$ts" "$rc"
  fi
  exit "$rc"
fi

if ! command -v watchexec >/dev/null; then
  echo "watch-rebuild: watchexec not on PATH; install pkgs.watchexec" >&2
  exit 1
fi

printf 'Watching %s (debounce: %ss); automatic builds only.\n' "$REPO_DIR" "$DEBOUNCE_SECS"
printf 'Build: nix build .#%s\nPress Ctrl-C to stop.\n' "$BUILD_ATTR"

# Watch source paths explicitly: a recursive scan of the repo would follow
# the result symlink into /nix/store. Keep this list in sync with the flake.
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
  -- "${REPO_DIR}/scripts/watch-rebuild.sh" --__build
