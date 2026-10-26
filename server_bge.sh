#!/bin/bash
# Run the embedding server on :9094, CPU only (no GPU, so the Qwen chat server keeps its VRAM).
# bge-m3 Q8_0 (~635MB, multilingual, 8k context), downloaded from Hugging Face on first run.
# Port via BGE_PORT (default 9094). Extra args are passed through to llama-server.
set -euo pipefail
cd "$(dirname "$0")"

BGE_PORT=${BGE_PORT:-9094}

# --device none: no GPU offload. -ub = -b = 8192 because an encoder model needs the whole input in one ubatch.
exec ./llama.cpp/build/bin/llama-server -hf gpustack/bge-m3-GGUF:Q8_0 --embeddings --device none \
  -c 8192 -b 8192 -ub 8192 -t 4 --host 0.0.0.0 --port "$BGE_PORT" "$@"
