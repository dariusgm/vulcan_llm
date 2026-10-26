# vulcan_llm — local LLM coding server on an AMD RX 5700 XT

Scripts to reproduce a local llama.cpp (Vulkan) server plus an OpenCode config.

> **Hardware warning:** this setup was tested **only** on one machine:
> **AMD Radeon RX 5700 XT (8 GB VRAM, RADV/Navi10), AMD Ryzen 9 5950X (16C/32T), 128 GB DDR4-3200 (4x32 GB), Ubuntu 22.04.**
> Every tuning value (offloaded layers, thread counts, batch sizes, clock pinning, GPU paths, model choice)
> comes from measurements on that box. On any other GPU, RAM size, CPU or distro, results may
> **vary deeply** — it may be slower, run out of memory, or not work at all. Treat the numbers as a starting
> point and re-benchmark (`llama-bench`) instead of trusting them.

## Files

| File | Purpose |
|---|---|
| `setup.sh` | One-time install and build |
| `server.sh` | Starts both servers: `server_bge.sh` in the background, then `server_qwen.sh` in the foreground |
| `stop.sh` | Stops both servers via `stop_qwen.sh` and `stop_bge.sh` |
| `server_qwen.sh` | Qwen chat server on `0.0.0.0:9931` (GPU, tunes GPU clocks with sudo) |
| `stop_qwen.sh` | Stops the Qwen server (SIGTERM, SIGKILL after a timeout) |
| `server_bge.sh` | bge-m3 embedding server on `0.0.0.0:9932` (CPU only) |
| `stop_bge.sh` | Stops the embedding server (same behavior as `stop_qwen.sh`) |
| `opencode.jsonc` | OpenCode config, copy to `~/.config/opencode/opencode.jsonc` |

## setup.sh

0. Aborts unless at least 100 GB are free where the model is cached (`$HF_HOME`, default `~/.cache/huggingface`); the model is ~89 GB.
1. Installs build dependencies via apt (cmake, Vulkan dev packages, glslang, curl/ssl dev, ...).
2. Ubuntu 22.04's apt has no `glslc` and its Vulkan headers (1.3.204) are too old for current llama.cpp.
   The script downloads the LunarG Vulkan SDK (1.4.363.0), copies `glslc` to `~/bin`, and builds against the
   SDK headers via `-isystem`. (Work dir `~/tmp`, override with `WORK=`; it can be deleted afterwards.)
3. Clones llama.cpp and builds `llama-server` and `llama-bench` with `-DGGML_VULKAN=ON`, native CPU flags and LTO.
4. Writes a udev rule setting the GPU's `power/control=on`. Otherwise amdgpu runtime-suspends the GPU during
   short idle gaps and evicts all VRAM to system RAM, so weights are then read over PCIe. This alone took the
   177B model from 5.6 to 11 t/s. For permanence you can also add the kernel parameter `amdgpu.runpm=0`.

## server.sh (both servers)

`./server.sh` starts the embedding server in the background (log: `server_bge.log`) and then runs
`server_qwen.sh` in the foreground (log: whatever `server.sh` writes to stdout). `./stop.sh` stops both.
Extra arguments go to the Qwen server.

## server_bge.sh (embeddings, CPU)

`bge-m3` Q8_0 (~635 MB, multilingual, 8k context), port `9932` (`BGE_PORT` overrides it).
Runs with `--device none`, so it uses no VRAM and leaves the GPU to the chat model. `-t 4` keeps it from
competing with the chat model's 12 threads. Batch and ubatch are both 8192, since an encoder needs the whole input in one ubatch.

Test: `curl localhost:9932/v1/embeddings -H 'Content-Type: application/json' -d '{"input":"Hallo"}'` returns 1024-dimensional vectors.

## server_qwen.sh (chat)

Requires sudo. First it pins GPU state (runtime PM off, manual DPM with memory clock at max, sclk levels 1–2);
the default auto DPM left the memory clock at 500 MHz. Then it starts `llama-server` on port `9931`
(`QWEN_PORT` overrides it; 9931 is the port llama.cpp's notice says will become the default).

**Model: `Qwen3.8-Flash-Next` 177B (UD-IQ4_XS, ~89 GB)** — downloaded from Hugging Face on first run; needs the RAM (128 GB here).
- `--cpu-moe`: all experts on CPU, dense weights (~4.5 GB) on the GPU. Moving experts to the GPU was
  *slower* for this model's quant types on Vulkan.
- `-c 32768`, `-t 12`, `-ub 1024 -b 2048`, `-fa on`, `-lm none` (this llama.cpp's replacement for
  `--no-mmap`), single slot, `--no-mmproj` (saves VRAM), reasoning effort medium.
- Measured: ~14 t/s generation, ~136–177 t/s prompt processing.

Why this model: it gives consistent tool execution in OpenCode's agentic mode. A smaller
Qwen3-Coder-30B-A3B was about 2x faster (~25–29 t/s) but its tool calls were inconsistent, so it was dropped.

Extra arguments are passed to `llama-server`. To change the port, set `QWEN_PORT` (e.g. `QWEN_PORT=8081 ./server.sh`).

## OpenCode

Copy `opencode.jsonc` to `~/.config/opencode/`. It defines a `llamacpp` provider pointing at
`http://127.0.0.1:9931/v1` with the model `qwen3.8-flash-next` (an alias, since llama-server serves whatever
it loaded), set as the default.

Tips: OpenCode's system prompt is ~10k tokens, so the first request needs a ~75 s prefill; later turns hit
the prompt cache. If `opencode run` seems to hang silently, add `--print-logs`.
