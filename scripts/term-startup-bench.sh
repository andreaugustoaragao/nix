#!/usr/bin/env bash
set -euo pipefail

# term-startup-bench.sh
#
# Compare terminal cold-start time: fresh process, one new window, exit when the
# inner command finishes. Same fair methodology as the scroll benchmark.
#
# Usage:
#   ./scripts/term-startup-bench.sh
#   RUNS=12 TERMINALS=foot,kitty ./scripts/term-startup-bench.sh
#
# Inner command defaults to `true`. Override with STARTUP_CMD='sleep 0.1' etc.

RUNS="${RUNS:-12}"
WARMUP="${WARMUP:-1}"
TERMINALS="${TERMINALS:-foot,kitty,alacritty,ghostty,xterm}"
STARTUP_CMD="${STARTUP_CMD:-true}"
XTERM_FONT="${XTERM_FONT:-CaskaydiaMono Nerd Font}"
XTERM_FONTSIZE="${XTERM_FONTSIZE:-10}"

export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
export DISPLAY="${DISPLAY:-:0}"

if ! command -v hyperfine >/dev/null; then
  echo "term-startup-bench: hyperfine not on PATH; install pkgs.hyperfine" >&2
  exit 1
fi

PREP='pkill -x foot 2>/dev/null || true; pkill -x kitty 2>/dev/null || true; pkill -x alacritty 2>/dev/null || true; pkill -x ghostty 2>/dev/null || true; pkill -x xterm 2>/dev/null || true; sleep 0.25'

log() {
  printf '\033[1;34m[term-startup-bench]\033[0m %s\n' "$*"
}

resolve_xterm() {
  if [[ -n "${XTERM_BIN:-}" && -x "$XTERM_BIN" ]]; then
    return 0
  fi
  if command -v xterm >/dev/null; then
    XTERM_BIN=$(command -v xterm)
    return 0
  fi
  if command -v nix >/dev/null; then
    XTERM_BIN="$(nix build --no-link --print-out-paths nixpkgs#xterm)/bin/xterm"
    return 0
  fi
  return 1
}

launch_cmd() {
  local term=$1
  case "$term" in
    foot)
      printf 'foot -e %q' "$STARTUP_CMD"
      ;;
    kitty)
      printf 'kitty --override single_instance=false -e %q --wait-for-close' "$STARTUP_CMD"
      ;;
    alacritty)
      printf 'alacritty -e %q' "$STARTUP_CMD"
      ;;
    ghostty)
      printf 'ghostty --gtk-single-instance=false -e %q' "$STARTUP_CMD"
      ;;
    xterm)
      printf '%q -fa %q -fs %q -e %q' \
        "$XTERM_BIN" "$XTERM_FONT" "$XTERM_FONTSIZE" "$STARTUP_CMD"
      ;;
    *)
      echo "term-startup-bench: unknown terminal: $term" >&2
      return 1
      ;;
  esac
}

term_available() {
  local term=$1
  case "$term" in
    foot | kitty | alacritty | ghostty)
      command -v "$term" >/dev/null
      ;;
    xterm)
      resolve_xterm
      ;;
    *)
      return 1
      ;;
  esac
}

main() {
  local -a selected=()
  local -a hf_args=()
  local IFS=,
  local term

  read -ra want <<<"$TERMINALS"
  for term in "${want[@]}"; do
    term=${term// /}
    [[ -z "$term" ]] && continue
    if term_available "$term"; then
      selected+=("$term")
    else
      log "skipping $term (not available)"
    fi
  done

  if [[ ${#selected[@]} -eq 0 ]]; then
    echo "term-startup-bench: no terminals available from: $TERMINALS" >&2
    exit 1
  fi

  log "terminals: ${selected[*]}"
  log "WAYLAND_DISPLAY=$WAYLAND_DISPLAY DISPLAY=$DISPLAY"
  log "startup cmd: $STARTUP_CMD"
  log "runs=$RUNS warmup=$WARMUP"
  echo

  for term in "${selected[@]}"; do
    hf_args+=(-n "$term" "$PREP; $(launch_cmd "$term")")
  done

  hyperfine \
    --warmup "$WARMUP" \
    --runs "$RUNS" \
    "${hf_args[@]}"
}

main "$@"
