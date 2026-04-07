#!/usr/bin/env bash

set -euo pipefail

# Drill down inside the current user's session.slice to find which app/service
# cgroups are accumulating unevictable memory, and map to processes.

limit=${LIMIT:-30}
interval=${INTERVAL:-3}

print_overall() {
  echo "==== overall ===="
  grep -E '^(Unevictable|Mlocked|Shmem|SUnreclaim)' /proc/meminfo || true
}

find_session_slices() {
  # Attempts to locate the user's session.slice path(s) under cgroup v2
  find /sys/fs/cgroup/user.slice -type d -path '*/user@*.service/session.slice' -maxdepth 8 2>/dev/null || true
}

snapshot_cg_uv() {
  # Args: cgroup_dir
  # Prints: cg_path|unit|uv_bytes
  local root="$1"
  find "$root" -maxdepth 3 -type f -name memory.stat -print0 2>/dev/null | while IFS= read -r -d '' stat; do
    local uv cg unit
    uv=$(awk '/^unevictable[[:space:]]+/ {print $2}' "$stat" 2>/dev/null || true)
    [[ -z "${uv:-}" ]] && uv=0
    (( uv > 0 )) || continue
    cg=$(dirname "$stat")
    unit=$(echo "$cg" | tr '/' '\n' | grep -E '\.(service|scope|slice)$' | head -n1 || true)
    printf '%s|%s|%s\n' "$cg" "${unit:-no-unit}" "$uv"
  done
}

print_top_children() {
  # Args: session_slice_dir
  local sess="$1"
  echo "==== top children by unevictable (KB) in: $sess ===="
  snapshot_cg_uv "$sess" |
    awk -F'|' '{kb=$3/1024; printf "%10.0f KB\t%-40s\t%s\n", kb, $2, $1}' |
    sort -nr | head -n "$limit"
}

growth_sample_children() {
  # Args: session_slice_dir, interval
  local sess="$1"; local sec="$2"
  local t1 t2
  t1=$(mktemp); t2=$(mktemp)
  snapshot_cg_uv "$sess" | sort -t '|' -k1,1 >"$t1"
  sleep "$sec"
  snapshot_cg_uv "$sess" | sort -t '|' -k1,1 >"$t2"
  echo "==== growth (KB) over ${sec}s in: $sess ===="
  join -t '|' -1 1 -2 1 -o '1.1,1.2,1.3,2.3' "$t1" "$t2" |
    awk -F'|' '{d=$4-$3; if (d>0) { printf "%10.0f KB\t%-40s\t%s\n", d/1024, $2, $1 }}' |
    sort -nr | head -n "$limit"
  rm -f "$t1" "$t2"
}

list_pids_for_cg() {
  # Args: cg_dir
  local cg="$1"
  if [[ -f "$cg/cgroup.procs" ]]; then
    sed 's/^/pid=/' "$cg/cgroup.procs" 2>/dev/null || true
  fi
}

print_top_cg_with_pids() {
  # Args: session_slice_dir
  local sess="$1"
  echo "==== offenders (top ${limit}) with PIDs in: $sess ===="
  snapshot_cg_uv "$sess" |
    sort -t '|' -k3,3nr |
    head -n "$limit" |
    while IFS='|' read -r cg unit uv; do
      printf '%10.0f KB\t%-40s\t%s\n' "$((uv/1024))" "$unit" "$cg"
      if [[ -f "$cg/cgroup.procs" ]]; then
        while read -r pid; do
          [[ -z "$pid" ]] && continue
          comm=$(tr -d '\0' <"/proc/$pid/comm" 2>/dev/null || echo unknown)
          exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
          printf '    pid=%-7s comm=%-24s exe=%s\n' "$pid" "$comm" "${exe:-}"
        done <"$cg/cgroup.procs"
      fi
    done
}

main() {
  print_overall
  local sessions
  mapfile -t sessions < <(find_session_slices)
  if (( ${#sessions[@]} == 0 )); then
    echo "No session.slice found under /sys/fs/cgroup/user.slice."
    exit 0
  fi
  for sess in "${sessions[@]}"; do
    print_top_children "$sess"
    if (( interval > 0 )); then
      growth_sample_children "$sess" "$interval"
    fi
    print_top_cg_with_pids "$sess"
  done
}

main "$@"



