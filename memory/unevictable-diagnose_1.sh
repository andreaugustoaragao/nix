#!/usr/bin/env bash

set -euo pipefail

print_overall() {
  echo "==== overall ===="
  grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Unevictable|Mlocked|Shmem|SUnreclaim)' /proc/meminfo || true
}

snapshot_cgroups() {
  # Prints: cg_path|unit|unevictable_bytes
  local root="${1:-/sys/fs/cgroup}"
  find "$root" -maxdepth 6 -type f -name memory.stat -print0 2>/dev/null |
    while IFS= read -r -d '' stat; do
      local uv cg unit
      uv=$(awk '/^unevictable[[:space:]]+/ {print $2}' "$stat" 2>/dev/null || true)
      [[ -z "${uv:-}" ]] && uv=0
      if (( uv > 0 )); then
        cg=$(dirname "$stat")
        unit=$(echo "$cg" | tr '/' '\n' | grep -E '\.(service|scope|slice)$' | head -n1 || true)
        printf '%s|%s|%s\n' "$cg" "${unit:-no-unit}" "$uv"
      fi
    done
}

print_top_cgroups_snapshot() {
  local limit=${1:-30}
  echo "==== top cgroups by unevictable (KB) ===="
  snapshot_cgroups /sys/fs/cgroup |
    awk -F'|' '{kb=$3/1024; printf "%10.0f KB\t%-40s\t%s\n", kb, $2, $1}' |
    sort -nr | head -n "$limit"
}

print_growth_sample() {
  local interval_sec=${1:-10}
  local limit=${2:-30}
  local tmp1 tmp2
  tmp1=$(mktemp)
  tmp2=$(mktemp)
  snapshot_cgroups /sys/fs/cgroup | sort -t '|' -k1,1 >"$tmp1"
  sleep "$interval_sec"
  snapshot_cgroups /sys/fs/cgroup | sort -t '|' -k1,1 >"$tmp2"
  echo "==== cgroup unevictable growth (KB) over ${interval_sec}s ===="
  # Join on cg_path, output: cg|unit|uv1|uv2, then compute delta
  join -t '|' -1 1 -2 1 -o '1.1,1.2,1.3,2.3' "$tmp1" "$tmp2" |
    awk -F'|' '{d=$4-$3; if (d>0) { printf "%10.0f KB\t%-40s\t%s\n", d/1024, $2, $1 }}' |
    sort -nr | head -n "$limit"
  rm -f "$tmp1" "$tmp2"
}

print_top_locked_procs() {
  local limit=${1:-40}
  echo "==== top processes by Locked (KB) ===="
  # Format: locked_kb|pid|comm|unit
  for f in /proc/[0-9]*/smaps_rollup; do
    local pid locked_kb comm cg unit
    pid=$(basename "$(dirname "$f")")
    locked_kb=$(awk '/^Locked:/ {print $2}' "$f" 2>/dev/null || echo 0)
    [[ -z "${locked_kb:-}" ]] && locked_kb=0
    if (( locked_kb > 0 )); then
      comm=$(tr -d '\0' <"/proc/$pid/comm" 2>/dev/null || echo unknown)
      cg=$(awk -F: '/^0:/{print $3}' "/proc/$pid/cgroup" 2>/dev/null || true)
      unit=$(echo "${cg:-}" | tr '/' '\n' | grep -E '\.(service|scope|slice)$' | head -n1 || true)
      printf '%s|%s|%s|%s\n' "$locked_kb" "$pid" "$comm" "${unit:-no-unit}"
    fi
  done |
    sort -nr -t '|' -k1,1 |
    head -n "$limit" |
    awk -F'|' '{printf "%10d KB\tpid=%-7s\t%-30s\t%s\n", $1, $2, $3, $4}'
}

usage() {
  cat <<EOF
Usage: $0 [-i SECONDS] [-n TOP]

Options:
  -i SECONDS   Sample growth over SECONDS (default: 0 = no growth sample)
  -n TOP       Show top TOP entries (default: 30 for cgroups, 40 for procs)
EOF
}

main() {
  local interval=0
  local topn=30
  while getopts ":i:n:h" opt; do
    case "$opt" in
      i) interval="$OPTARG" ;;
      n) topn="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) echo "Option -$OPTARG requires an argument" >&2; usage; exit 1 ;;
      \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 1 ;;
    esac
  done

  print_overall
  print_top_cgroups_snapshot "$topn"
  if (( interval > 0 )); then
    print_growth_sample "$interval" "$topn"
  fi
  print_top_locked_procs 40
}

main "$@"



