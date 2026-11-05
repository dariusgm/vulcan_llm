#!/bin/bash
# One-time setup: Ubuntu 22.04, RX 5700 XT (RADV), llama.cpp with Vulkan.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK_VER=1.4.363.0
WORK="${WORK:-$HOME/tmp}"

# Models are stored in the Hugging Face cache, the same layout llama-server -hf reads.
HF_DIR="${HF_HOME:-$HOME/.cache/huggingface}"
QWEN_REPO=unsloth/Qwen3.8-Flash-Next-GGUF
QWEN_PATTERN="UD-IQ4_XS/*"
QWEN_SHARDS=(UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-0000{1,2,3,4}-of-00004.gguf)
BGE_REPO=gpustack/bge-m3-GGUF
BGE_PATTERN="bge-m3-Q8_0.gguf"

# have_model <repo-dir-name> <file>...: true if every file is in the local HF cache
have_model() {
  local dir=$1; shift
  local f
  for f in "$@"; do
    compgen -G "$HF_DIR/hub/$dir/snapshots/*/$f" > /dev/null || return 1
  done
}
QWEN_PRESENT=0; BGE_PRESENT=0
have_model models--unsloth--Qwen3.8-Flash-Next-GGUF "${QWEN_SHARDS[@]}" && QWEN_PRESENT=1
have_model models--gpustack--bge-m3-GGUF "$BGE_PATTERN" && BGE_PRESENT=1

# 0. disk space: the Qwen model (~89GB) is downloaded in step 5 if it is not cached yet
MIN_GB=100
CHECK_DIR="$HF_DIR"
while [ ! -d "$CHECK_DIR" ]; do CHECK_DIR="$(dirname "$CHECK_DIR")"; done
AVAIL_GB=$(df -BG --output=avail "$CHECK_DIR" | tail -1 | tr -dc 0-9)
if [ "$QWEN_PRESENT" = 1 ]; then
  echo "Model already in $HF_DIR, skipping disk check (${AVAIL_GB}GB free)"
elif [ "$AVAIL_GB" -lt "$MIN_GB" ]; then
  echo "ERROR: only ${AVAIL_GB}GB free for $HF_DIR, need at least ${MIN_GB}GB (model ~89GB)." >&2
  echo "Free up space or set HF_HOME to a bigger disk." >&2
  exit 1
else
  echo "Disk check OK: ${AVAIL_GB}GB free for $HF_DIR"
fi

# 1. build deps (apt has no glslc, and its Vulkan headers 1.3.204 are too old)
sudo apt-get update
sudo apt-get install -y git cmake build-essential libvulkan-dev glslang-tools \
  spirv-tools spirv-headers vulkan-tools libcurl4-openssl-dev libssl-dev python3-pip

# 2. glslc + recent Vulkan headers from the LunarG SDK
mkdir -p "$WORK/sdk" "$HOME/bin"
if [ ! -d "$WORK/sdk/$SDK_VER" ]; then
  curl -L -o "$WORK/sdk.tar.xz" \
    "https://sdk.lunarg.com/sdk/download/$SDK_VER/linux/vulkansdk-linux-x86_64-$SDK_VER.tar.xz"
  rm -rf "$WORK/sdk/$SDK_VER"
  tar -xf "$WORK/sdk.tar.xz" -C "$WORK/sdk"
fi
cp "$WORK/sdk/$SDK_VER/x86_64/bin/glslc" "$HOME/bin/glslc"
export PATH="$HOME/bin:$PATH"
VKINC="$WORK/sdk/$SDK_VER/x86_64/include"

# 3. llama.cpp with Vulkan
[ -d "$ROOT/llama.cpp" ] || git clone https://github.com/ggml-org/llama.cpp "$ROOT/llama.cpp"
cmake -S "$ROOT/llama.cpp" -B "$ROOT/llama.cpp/build" -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON -DGGML_LTO=ON -DVulkan_INCLUDE_DIR="$VKINC" \
  -DCMAKE_C_FLAGS="-isystem $VKINC" -DCMAKE_CXX_FLAGS="-isystem $VKINC"
cmake --build "$ROOT/llama.cpp/build" -j"$(nproc)" --target llama-server llama-bench

# 4. Keep the GPU from runtime-suspending (otherwise amdgpu evicts VRAM to RAM on every
#    idle gap and dense weights get read over PCIe: 5.6 -> 11 t/s). Persist via udev.
PCI=$(basename "$(readlink -f "$(grep -l 0x1002 /sys/class/drm/card*/device/vendor | head -1 | xargs dirname)")")
echo "ACTION==\"add\", SUBSYSTEM==\"pci\", KERNEL==\"$PCI\", ATTR{power/control}=\"on\"" \
  | sudo tee /etc/udev/rules.d/99-amdgpu-nopm.rules
# optionally also add kernel param amdgpu.runpm=0 for permanence

# 5. models: download what is missing into the HF cache (skipped if already there)
if [ "$QWEN_PRESENT" = 1 ] && [ "$BGE_PRESENT" = 1 ]; then
  echo "Models already cached in $HF_DIR, nothing to download."
else
  if ! python3 -c 'import huggingface_hub' 2>/dev/null; then
    python3 -m pip install --user -q huggingface_hub
  fi
  # download <repo> <allow-pattern>: resumable, skips files that are already complete
  download() {
    python3 -c 'import sys
from huggingface_hub import snapshot_download
print(snapshot_download(repo_id=sys.argv[1], allow_patterns=[sys.argv[2]]))' "$1" "$2"
  }
  if [ "$BGE_PRESENT" = 0 ]; then
    echo "Downloading $BGE_REPO ($BGE_PATTERN, ~635MB)..."
    download "$BGE_REPO" "$BGE_PATTERN"
  fi
  if [ "$QWEN_PRESENT" = 0 ]; then
    echo "Downloading $QWEN_REPO ($QWEN_PATTERN, ~89GB), this takes a while..."
    download "$QWEN_REPO" "$QWEN_PATTERN"
  fi
  # verify again: a partial download must not look like a finished one
  have_model models--unsloth--Qwen3.8-Flash-Next-GGUF "${QWEN_SHARDS[@]}" || { echo "ERROR: Qwen model incomplete" >&2; exit 1; }
  have_model models--gpustack--bge-m3-GGUF "$BGE_PATTERN" || { echo "ERROR: bge-m3 model incomplete" >&2; exit 1; }
  echo "Models cached in $HF_DIR."
fi

echo "Done. Start both servers with ./server.sh"
