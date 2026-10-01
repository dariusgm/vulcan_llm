#!/bin/bash
# Run llama-server on :8080 (RX 5700 XT 8GB + Ryzen 5950X, 128GB RAM).
# Qwen3.8-Flash-Next 177B UD-IQ4_XS, dense weights on GPU, all experts on CPU (~14 t/s).
# Downloads the model (~89GB) from Hugging Face on first run.
# Extra args are passed through to llama-server.
set -euo pipefail
cd "$(dirname "$0")"

# GPU tuning (needs root): no runtime suspend, pin memory clock to max (+13.9 vs 5.6 t/s)
D=$(dirname "$(grep -l 0x1002 /sys/class/drm/card*/device/vendor | head -1)")
sudo sh -c "echo on > $D/power/control
echo manual > $D/power_dpm_force_performance_level
echo 3 > $D/pp_dpm_mclk
echo '1 2' > $D/pp_dpm_sclk"

exec ./llama.cpp/build/bin/llama-server -hf unsloth/Qwen3.8-Flash-Next-GGUF:UD-IQ4_XS --no-mmproj \
  --jinja -ngl 999 --cpu-moe -fa on -c 131072 -t 12 -lm none -b 2048 -ub 1024 --host 0.0.0.0 --mmproj-auto --parallel 4 \
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --chat-template-kwargs '{"reasoning_effort":"medium"}' "$@"
