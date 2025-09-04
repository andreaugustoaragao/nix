#!/usr/bin/env bash

set -euo pipefail

limit=${LIMIT:-25}
interval=${INTERVAL:-3}

print_overall() {
  echo "==== overall ===="
  grep -E '^(Unevictable|Mlocked|Shmem|SUnreclaim)' /proc/meminfo || true
}

find_session_slices() {
  find /sys/fs/cgroup/user.slice -type d -path '*/user@*.service/session.slice' -maxdepth 8 2>/dev/null || true
}

list_session_pids() {
  local sess="$1"
  find "$sess" -type f -name cgroup.procs -print0 2>/dev/null |
    xargs -0 -I{} cat {} 2>/dev/null |
    awk 'NF>0' |
    sort -u
}

snapshot_pids() {
  # Args: session_dir
  # Prints: pid|shmem_kb|locked_kb|comm|unit
  local sess="$1"
  list_session_pids "$sess" |
    while read -r pid; do
      [[ -d "/proc/$pid" ]] || continue
      local shmem locked comm cg unit
      shmem=$(awk '/^Shmem:/ {print $2}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo 0)
      locked=$(awk '/^Locked:/ {print $2}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo 0)
      comm=$(tr -d '\0' <"/proc/$pid/comm" 2>/dev/null || echo unknown)
      cg=$(awk -F: '/^0:/{print $3}' "/proc/$pid/cgroup" 2>/dev/null || true)
      unit=$(echo "${cg:-}" | tr '/' '\n' | grep -E '\\.(service|scope|slice)$' | head -n1 || true)
      printf '%s|%s|%s|%s|%s\n' "$pid" "${shmem:-0}" "${locked:-0}" "$comm" "${unit:-no-unit}"
    done
}

print_top_current() {
  local sess="$1"
  echo "==== top processes by Shmem (KB) in session: $sess ===="
  snapshot_pids "$sess" |
    awk -F'|' '{printf "%10d KB\tpid=%-7s\t%-28s\t%s\n", $2, $1, $4, $5}' |
    sort -nr | head -n "$limit"
}

growth_sample_procs() {
  local sess="$1"; local sec="$2"
  local t1 t2
  t1=$(mktemp); t2=$(mktemp)
  snapshot_pids "$sess" | sort -t '|' -k1,1 >"$t1"
  sleep "$sec"
  snapshot_pids "$sess" | sort -t '|' -k1,1 >"$t2"
  echo "==== per-process Shmem growth (KB) over ${sec}s in: $sess ===="
  join -t '|' -1 1 -2 1 -o '1.1,1.2,1.3,1.4,1.5,2.2,2.3' "$t1" "$t2" |
    awk -F'|' '{d=$6-$2; if (d>0) { printf "%10d KB\tpid=%-7s\t%-28s\t%s\n", d, $1, $4, $5 }}' |
    sort -nr | head -n "$limit"
  rm -f "$t1" "$t2"
}

memfd_summary_for_pid() {
  local pid="$1"
  local total count_memfd count_shm
  total=0; count_memfd=0; count_shm=0
  if [[ -d "/proc/$pid/fd" ]]; then
    while read -r link; do
      (( total++ ))
      case "$link" in
        *memfd:*) (( count_memfd++ )) ;;
        *shm*|*/shm/*) (( count_shm++ )) ;;
      esac
    done < <(ls -l "/proc/$pid/fd" 2>/dev/null | awk '{print $NF}' || true)
  fi
  printf 'fds=%d memfd=%d shm=%d' "$total" "$count_memfd" "$count_shm"
}

print_details_for_top() {
  local sess="$1"; local sec="$2"
  echo "==== details for top offenders (Shmem delta) ===="
  local t1 t2 top_pids
  t1=$(mktemp); t2=$(mktemp)
  snapshot_pids "$sess" | sort -t '|' -k1,1 >"$t1"
  sleep "$sec"
  snapshot_pids "$sess" | sort -t '|' -k1,1 >"$t2"
  join -t '|' -1 1 -2 1 -o '1.1,1.2,1.4,1.5,2.2' "$t1" "$t2" |
    awk -F'|' '{d=$5-$2; if (d>0) { printf "%s|%d|%s|%s|%d\n", $1, d, $3, $4, $5}}' |
    sort -t '|' -k2,2nr | head -n "$limit" |
    while IFS='|' read -r pid delta_kb comm unit new_shmem; do
      detail=$(memfd_summary_for_pid "$pid")
      exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
      printf '%10d KB\tpid=%-7s\t%-28s\t%-20s\t%s\n' "$delta_kb" "$pid" "$comm" "$unit" "$exe"
      printf '    %s\n' "$detail"
    done
  rm -f "$t1" "$t2"
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
    print_top_current "$sess"
    if (( interval > 0 )); then
      growth_sample_procs "$sess" "$interval"
      print_details_for_top "$sess" "$interval"
    fi
  done
}

main "$@"


