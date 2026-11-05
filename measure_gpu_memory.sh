#!/bin/bash
# Snapshot of AMD GPU memory and its GPU clients. Prints to stdout and appends to measure_gpu_memory.log.
# Run right after boot (before starting apps) to get the baseline.
set -uo pipefail
cd "$(dirname "$0")"

D=$(dirname "$(grep -l 0x1002 /sys/class/drm/card*/device/vendor | head -1)")
LOG=measure_gpu_memory.log

{
  echo "=== $(date '+%F %T') | uptime: $(uptime -p) | session: ${XDG_SESSION_TYPE:-?}"
  echo "VRAM used: $(( $(cat "$D/mem_info_vram_used") / 1048576 )) / $(( $(cat "$D/mem_info_vram_total") / 1048576 )) MiB"
  echo "GTT used:  $(( $(cat "$D/mem_info_gtt_used") / 1048576 )) MiB"

  echo "-- GPU clients (VRAM MiB, pid, name):"
  for f in /proc/[0-9]*/fdinfo/*; do
    grep -qs '^drm-driver:.*amdgpu' "$f" || continue
    pid=${f#/proc/}; pid=${pid%%/*}
    awk -v pid="$pid" '/^drm-client-id:/{c=$2} /^drm-memory-vram:/{v=$2} END{print pid, c, v+0}' "$f"
  done 2>/dev/null | sort -u | awk '{m[$1]+=$3} END{for(p in m) print int(m[p]/1024), p}' | sort -rn | head -10 |
    while read -r mb pid; do echo "   ${mb} MiB  pid ${pid}  $(ps -o comm= -p "$pid")"; done

  echo "-- desktop processes (RSS MiB):"
  for name in gnome-shell Xorg; do
    for p in $(pgrep -x "$name" 2>/dev/null); do
      echo "   $name pid $p: $(( $(awk '/VmRSS/{print $2}' /proc/$p/status) / 1024 ))"
    done
  done

  echo "-- monitors:"
  xrandr --listmonitors 2>/dev/null | sed 's/^/   /' || echo "   xrandr unavailable"
  echo
} | tee -a "$LOG"
