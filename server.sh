#!/bin/bash
# Run llama-server on :8080 (RX 5700 XT 8GB + Ryzen 5950X, 128GB RAM).
# Qwen3.8-Flash-Next 177B UD-IQ4_XS, dense weights on GPU, all experts on CPU (~14 t/s).
# Downloads the model (~89GB) from Hugging Face on first run.
# Extra args are passed through to llama-server.
set -euo pipefail
cd "$(dirname "$0")"

D=$(dirname "$(grep -l 0x1002 /sys/class/drm/card*/device/vendor | head -1)")

# Preflight: refuse to start (before loading ~89GB) if the GPU or RAM is already too busy.
# A failed start under VRAM pressure ends in "device lost" after minutes of loading.
# Tunable via env: MIN_FREE_VRAM_MB, RAM_HEADROOM_MB, SKIP_PREFLIGHT=1 to bypass.
MIN_FREE_VRAM_MB=${MIN_FREE_VRAM_MB:-7400}   # weights+mmproj+KV+buffers ~7.15GB, plus slack
RAM_HEADROOM_MB=${RAM_HEADROOM_MB:-16384}    # left for IDE, browsers, desktop
MODEL_MB_FALLBACK=91000                      # ~89GB, used before the first download

preflight() {
  local ok=1 vram_total vram_used vram_free model_mb avail_mb need_mb
  vram_total=$(( $(cat "$D/mem_info_vram_total") / 1048576 ))
  vram_used=$(( $(cat "$D/mem_info_vram_used") / 1048576 ))
  vram_free=$(( vram_total - vram_used ))
  echo "preflight: VRAM free ${vram_free} MiB (need ${MIN_FREE_VRAM_MB}, used ${vram_used}/${vram_total})"
  if (( vram_free < MIN_FREE_VRAM_MB )); then
    ok=0
    echo "  -> not enough free VRAM. Largest GPU users (VRAM MiB):"
    # one fdinfo entry per (pid, drm-client-id): the same client shows up on several fds
    for f in /proc/[0-9]*/fdinfo/*; do
      grep -qs '^drm-driver:.*amdgpu' "$f" || continue
      pid=${f#/proc/}; pid=${pid%%/*}
      awk -v pid="$pid" '/^drm-client-id:/{c=$2} /^drm-memory-vram:/{v=$2} END{print pid, c, v+0}' "$f"
    done 2>/dev/null | sort -u | awk '{m[$1]+=$3} END{for(p in m) print int(m[p]/1024), p}' | sort -rn | head -5 |
      while read -r mb pid; do echo "     ${mb} MiB  pid ${pid}  $(ps -o comm= -p "$pid")"; done
  fi

  # MemAvailable counts a page-cached model as available, so this holds with or without a warm cache.
  model_mb=$(du -sLm ~/.cache/huggingface/hub/models--unsloth--Qwen3.8-Flash-Next-GGUF/snapshots 2>/dev/null | cut -f1)
  [ "${model_mb:-0}" -gt 1000 ] || model_mb=$MODEL_MB_FALLBACK
  avail_mb=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
  need_mb=$(( model_mb + RAM_HEADROOM_MB ))
  echo "preflight: RAM available ${avail_mb} MiB (need ${need_mb} = model ${model_mb} + headroom ${RAM_HEADROOM_MB})"
  if (( avail_mb < need_mb )); then
    ok=0
    echo "  -> not enough free RAM. Largest processes (RSS MiB):"
    ps -eo rss=,comm= --sort=-rss | head -5 | awk '{printf "     %d MiB  %s\n", $1/1024, $2}'
  fi
  (( ok )) || { echo "preflight failed, not starting (SKIP_PREFLIGHT=1 to override)" >&2; exit 1; }
}
[ "${SKIP_PREFLIGHT:-0}" = 1 ] || preflight

# GPU tuning (needs root): no runtime suspend, pin memory clock to max (+13.9 vs 5.6 t/s)
sudo sh -c "echo on > $D/power/control
echo manual > $D/power_dpm_force_performance_level
echo 3 > $D/pp_dpm_mclk
echo '1 2' > $D/pp_dpm_sclk"

exec ./llama.cpp/build/bin/llama-server -hf unsloth/Qwen3.8-Flash-Next-GGUF:UD-IQ4_XS --no-mmproj \
  --jinja -ngl 999 --cpu-moe -fa on -c 180224 -t 12 -lm none -b 2048 -ub 1024 --host 0.0.0.0 --mmproj-auto --parallel 1 \
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --chat-template-kwargs '{"reasoning_effort":"medium"}' "$@"
