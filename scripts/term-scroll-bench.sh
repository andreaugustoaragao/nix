#!/usr/bin/env bash
set -euo pipefail

# term-scroll-bench.sh
#
# Compare terminal scroll/paint throughput by streaming a large file through
# each emulator. Uses cat (plain text) and bat (highlighted) so the terminal
# must render every line — unlike nvim batch mode, which often skips real TUI
# redraws.
#
# Usage:
#   ./scripts/term-scroll-bench.sh
#   LINES=50000 RUNS=5 ./scripts/term-scroll-bench.sh
#   TERMINALS=foot,kitty ./scripts/term-scroll-bench.sh
#
# Requirements: hyperfine, bat, at least one terminal on PATH.
# xterm is pulled from nixpkgs#xterm when absent from PATH.
#
# Methodology (matches prior VM benchmarks):
#   - Kill all known terminal processes before each run (cold single window)
#   - kitty: --override single_instance=false
#   - ghostty: --gtk-single-instance=false
#   - xterm: X11 via DISPLAY, CaskaydiaMono Nerd Font 10pt
#   - cat: unaliased system binary (fish aliases cat -> cat -v)

LINES="${LINES:-100000}"
RUNS="${RUNS:-8}"
WARMUP="${WARMUP:-1}"
BENCH_FILE="${BENCH_FILE:-/tmp/term-scroll-bench.txt}"
TERMINALS="${TERMINALS:-foot,kitty,alacritty,ghostty,xterm}"
XTERM_FONT="${XTERM_FONT:-CaskaydiaMono Nerd Font}"
XTERM_FONTSIZE="${XTERM_FONTSIZE:-10}"

export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
export DISPLAY="${DISPLAY:-:0}"

if ! command -v hyperfine >/dev/null; then
  echo "term-scroll-bench: hyperfine not on PATH; install pkgs.hyperfine" >&2
  exit 1
fi

if ! command -v bat >/dev/null; then
  echo "term-scroll-bench: bat not on PATH" >&2
  exit 1
fi

# Prefer the store cat — interactive fish aliases cat to cat -v.
if [[ -x /run/current-system/sw/bin/cat ]]; then
  CAT=/run/current-system/sw/bin/cat
else
  CAT=$(command -v cat)
fi

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

kill_terms() {
  pkill -x foot 2>/dev/null || true
  pkill -x kitty 2>/dev/null || true
  pkill -x alacritty 2>/dev/null || true
  pkill -x ghostty 2>/dev/null || true
  pkill -x xterm 2>/dev/null || true
  sleep 0.25
}

PREP='pkill -x foot 2>/dev/null || true; pkill -x kitty 2>/dev/null || true; pkill -x alacritty 2>/dev/null || true; pkill -x ghostty 2>/dev/null || true; pkill -x xterm 2>/dev/null || true; sleep 0.25'

log() {
  printf '\033[1;34m[term-scroll-bench]\033[0m %s\n' "$*"
}

generate_bench_file() {
  if [[ -f "$BENCH_FILE" ]]; then
    local existing_lines
    existing_lines=$(wc -l <"$BENCH_FILE" | tr -d ' ')
    if [[ "$existing_lines" -ge "$LINES" ]]; then
      log "using existing bench file $BENCH_FILE ($existing_lines lines)"
      return 0
    fi
  fi
  log "generating $BENCH_FILE ($LINES lines)..."
  seq "$LINES" >"$BENCH_FILE"
}

launch_cmd() {
  local term=$1
  local inner=$2
  case "$term" in
    foot)
      printf 'foot -e sh -c %q' "$inner"
      ;;
    kitty)
      printf 'kitty --override single_instance=false -e sh -c %q' "$inner"
      ;;
    alacritty)
      printf 'alacritty -e sh -c %q' "$inner"
      ;;
    ghostty)
      printf 'ghostty --gtk-single-instance=false -e sh -c %q' "$inner"
      ;;
    xterm)
      printf '%q -fa %q -fs %q -e sh -c %q' \
        "$XTERM_BIN" "$XTERM_FONT" "$XTERM_FONTSIZE" "$inner"
      ;;
    *)
      echo "term-scroll-bench: unknown terminal: $term" >&2
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

run_suite() {
  local workload=$1
  shift
  local inner=$1
  shift
  local -a hf_args=()
  local term

  log "=== $workload: streaming $LINES lines ==="

  for term in "$@"; do
    hf_args+=(-n "$term" "$PREP; $(launch_cmd "$term" "$inner")")
  done

  hyperfine \
    --warmup "$WARMUP" \
    --runs "$RUNS" \
    "${hf_args[@]}"
}

main() {
  local -a selected=()
  local IFS=,
  local raw term

  generate_bench_file
  kill_terms

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
    echo "term-scroll-bench: no terminals available from: $TERMINALS" >&2
    exit 1
  fi

  log "terminals: ${selected[*]}"
  log "WAYLAND_DISPLAY=$WAYLAND_DISPLAY DISPLAY=$DISPLAY"
  log "bench file: $BENCH_FILE ($LINES lines, $(wc -c <"$BENCH_FILE" | tr -d ' ') bytes)"
  log "runs=$RUNS warmup=$WARMUP"
  echo

  run_suite "cat" "$CAT $BENCH_FILE" "${selected[@]}"
  echo
  run_suite "bat" "bat --paging=never --color=always $BENCH_FILE" "${selected[@]}"
}

main "$@"
