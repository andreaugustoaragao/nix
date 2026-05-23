#!/usr/bin/env bash
set -euo pipefail

# term-bench.sh — run startup + scroll benchmarks and write JSON for reports.
#
# Usage:
#   ./scripts/term-bench.sh
#   OUT=reports/data/terminal-emulators-prl-dev-vm.json ./scripts/term-bench.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$REPO_DIR/reports/data/terminal-emulators-prl-dev-vm.json}"
HOST="$(hostname -s)"
RUNS="${RUNS:-8}"
WARMUP="${WARMUP:-1}"
LINES="${LINES:-100000}"
TERMINALS="${TERMINALS:-foot,kitty,alacritty,ghostty,xterm}"
BENCH_FILE="${BENCH_FILE:-/tmp/term-scroll-bench.txt}"
XTERM_FONT="${XTERM_FONT:-CaskaydiaMono Nerd Font}"
XTERM_FONTSIZE="${XTERM_FONTSIZE:-10}"

export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
export DISPLAY="${DISPLAY:-:0}"

if ! command -v hyperfine >/dev/null; then
  echo "term-bench: hyperfine not on PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null; then
  echo "term-bench: jq not on PATH" >&2
  exit 1
fi

if [[ -x /run/current-system/sw/bin/cat ]]; then
  CAT=/run/current-system/sw/bin/cat
else
  CAT=$(command -v cat)
fi

PREP='pkill -x foot 2>/dev/null || true; pkill -x kitty 2>/dev/null || true; pkill -x alacritty 2>/dev/null || true; pkill -x ghostty 2>/dev/null || true; pkill -x xterm 2>/dev/null || true; sleep 0.25'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$(dirname "$OUT")"

log() {
  printf '\033[1;34m[term-bench]\033[0m %s\n' "$*"
}

resolve_xterm() {
  if [[ -n "${XTERM_BIN:-}" && -x "$XTERM_BIN" ]]; then
    return 0
  fi
  if command -v xterm >/dev/null; then
    XTERM_BIN=$(command -v xterm)
    return 0
  fi
  XTERM_BIN="$(nix build --no-link --print-out-paths nixpkgs#xterm)/bin/xterm"
}

term_available() {
  case "$1" in
    foot | kitty | alacritty | ghostty) command -v "$1" >/dev/null ;;
    xterm) resolve_xterm ;;
    *) return 1 ;;
  esac
}

term_version() {
  case "$1" in
    foot) foot --version 2>/dev/null | head -1 ;;
    kitty) kitty --version 2>/dev/null | head -1 ;;
    alacritty) alacritty --version 2>/dev/null | head -1 ;;
    ghostty) ghostty +version 2>/dev/null | head -1 ;;
    xterm) "$XTERM_BIN" -version 2>&1 | head -1 ;;
  esac
}

launch_startup() {
  case "$1" in
    foot) echo "foot -e true" ;;
    kitty) echo "kitty --override single_instance=false -e true --wait-for-close" ;;
    alacritty) echo "alacritty -e true" ;;
    ghostty) echo "ghostty --gtk-single-instance=false -e true" ;;
    xterm) echo "$XTERM_BIN -fa '$XTERM_FONT' -fs $XTERM_FONTSIZE -e true" ;;
  esac
}

launch_scroll() {
  local mode=$1
  local inner
  case "$mode" in
    cat) inner="$CAT $BENCH_FILE" ;;
    bat) inner="bat --paging=never --color=always $BENCH_FILE" ;;
    *) return 1 ;;
  esac
  case "$2" in
    foot) echo "foot -e sh -c $(printf '%q' "$inner")" ;;
    kitty) echo "kitty --override single_instance=false -e sh -c $(printf '%q' "$inner")" ;;
    alacritty) echo "alacritty -e sh -c $(printf '%q' "$inner")" ;;
    ghostty) echo "ghostty --gtk-single-instance=false -e sh -c $(printf '%q' "$inner")" ;;
    xterm) echo "$XTERM_BIN -fa '$XTERM_FONT' -fs $XTERM_FONTSIZE -e sh -c $(printf '%q' "$inner")" ;;
  esac
}

run_suite() {
  local label=$1
  shift
  local -a hf=()
  local term cmd
  for term in "$@"; do
    cmd=$(launch_startup "$term")
    hf+=(-n "$term" "$PREP; $cmd")
  done
  log "hyperfine: $label ($# terminals)"
  hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$TMP/$label.json" "${hf[@]}"
}

run_scroll_suite() {
  local mode=$1
  shift
  local label="scroll_$mode"
  local -a hf=()
  local term cmd inner
  case "$mode" in
    cat) inner="$CAT $BENCH_FILE" ;;
    bat) inner="bat --paging=never --color=always $BENCH_FILE" ;;
  esac
  for term in "$@"; do
    cmd=$(launch_scroll "$mode" "$term")
    hf+=(-n "$term" "$PREP; $cmd")
  done
  log "hyperfine: $label ($# terminals)"
  hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$TMP/$label.json" "${hf[@]}"
}

main() {
  local -a selected=()
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
    echo "term-bench: no terminals available" >&2
    exit 1
  fi

  log "generating $BENCH_FILE ($LINES lines)..."
  seq "$LINES" >"$BENCH_FILE"

  run_suite startup "${selected[@]}"
  run_scroll_suite cat "${selected[@]}"
  run_scroll_suite bat "${selected[@]}"

  local -a version_json=()
  for term in "${selected[@]}"; do
    version_json+=("$(jq -n --arg t "$term" --arg v "$(term_version "$term")" '{terminal: $t, version: $v}')")
  done
  local versions
  versions=$(printf '%s\n' "${version_json[@]}" | jq -s '.')

  jq -n \
    --arg host "$HOST" \
    --arg time_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg repo "$REPO_DIR" \
    --arg uname "$(uname -a)" \
    --arg wayland "${WAYLAND_DISPLAY}" \
    --arg display "${DISPLAY}" \
    --argjson runs "$RUNS" \
    --argjson lines "$LINES" \
    --arg bench_file "$BENCH_FILE" \
    --argjson bench_bytes "$(wc -c <"$BENCH_FILE" | tr -d ' ')" \
    --argjson terminals "$(printf '%s\n' "${selected[@]}" | jq -R . | jq -s '.')" \
    --argjson versions "$versions" \
    --slurpfile startup "$TMP/startup.json" \
    --slurpfile scroll_cat "$TMP/scroll_cat.json" \
    --slurpfile scroll_bat "$TMP/scroll_bat.json" \
    '{
      metadata: {
        hostname: $host,
        time_utc: $time_utc,
        repo: $repo,
        uname: $uname,
        wayland_display: $wayland,
        display: $display,
        runs: $runs,
        methodology: {
          startup: "cold single process; inner cmd=true; kitty single_instance=false; ghostty gtk-single-instance=false",
          scroll: "stream full file to terminal; cat plain; bat --paging=never --color=always; kill all terminals before each run"
        },
        bench_file: $bench_file,
        bench_lines: $lines,
        bench_bytes: $bench_bytes,
        font: "CaskaydiaMono Nerd Font 10pt (xterm explicit; others from home-manager config)",
        terminals: $terminals,
        versions: $versions
      },
      results: {
        startup_ms: $startup[0],
        scroll_cat_ms: $scroll_cat[0],
        scroll_bat_ms: $scroll_bat[0]
      }
    }' >"$OUT"

  log "wrote $OUT"
}

main "$@"
