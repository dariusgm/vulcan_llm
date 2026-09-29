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
| `server.sh` | Tune the GPU and start `llama-server` on `127.0.0.1:8080` |
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

## server.sh

Requires sudo. First it pins GPU state (runtime PM off, manual DPM with memory clock at max, sclk levels 1–2);
the default auto DPM left the memory clock at 500 MHz. Then it starts `llama-server`.

**Model: `Qwen3.8-Flash-Next` 177B (UD-IQ4_XS, ~89 GB)** — downloaded from Hugging Face on first run; needs the RAM (128 GB here).
- `--cpu-moe`: all experts on CPU, dense weights (~4.5 GB) on the GPU. Moving experts to the GPU was
  *slower* for this model's quant types on Vulkan.
- `-c 32768`, `-t 12`, `-ub 1024 -b 2048`, `-fa on`, `-lm none` (this llama.cpp's replacement for
  `--no-mmap`), single slot, `--no-mmproj` (saves VRAM), reasoning effort medium.
- Measured: ~14 t/s generation, ~136–177 t/s prompt processing.

Why this model: it gives consistent tool execution in OpenCode's agentic mode. A smaller
Qwen3-Coder-30B-A3B was about 2x faster (~25–29 t/s) but its tool calls were inconsistent, so it was dropped.

Extra arguments are passed to `llama-server`, e.g. `./server.sh --port 8081`.

## OpenCode

Copy `opencode.jsonc` to `~/.config/opencode/`. It defines a `llamacpp` provider pointing at
`http://127.0.0.1:8080/v1` with the model `qwen3.8-flash-next` (an alias, since llama-server serves whatever
it loaded), set as the default.

Tips: OpenCode's system prompt is ~10k tokens, so the first request needs a ~75 s prefill; later turns hit
the prompt cache. If `opencode run` seems to hang silently, add `--print-logs`.
