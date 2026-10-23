# Performance: tune with measurements, not by feel

Principle: every important setting has a **benchmark experiment** that measures it (`lab bench ...`). A setting is only
changed when a measurement justifies it, and the result is written down here. The figures below come from the reference
machine.

## 1. GPU power limit

### Measurement (power-sweep)
RTX 3090, `qwen3.8:27b`, 2048 tokens of filled context, 256 tokens generated, 7 repetitions per level.
Baseline: 350 W (factory setting). **Measured with the remote desktop active** (see `remote-desktop-gpu.md`).

| Limit | Generation | vs 350 W | Prefill | J/token | SM clock |
|---|---|---|---|---|---|
| 350 W | 55.1 tok/s | baseline | 1,238 tok/s | 7.6 | 1,591 MHz |
| **300 W** | **50.3** | **−9 %** [−13; −3] | 1,166 | **6.8 (−10 %)** | 1,419 |
| 250 W | 40.7 | −26 % | 1,059 | 7.4 (≈ 350 W) | 1,088 |
| 220 W | 29.8 | −46 % | 889 | 8.5 | 855 |
| 200 W | 24.8 | −55 % | 750 | 9.2 | 662 |
| 180 W | 19.0 | −66 % | 575 | 10.9 | 506 |
| 150 W | 9.6 | −83 % | 316 | 17.7 | 245 |

Reading:
- **300 W is the best compromise**: the only level more energy-efficient than 350 W, for 9 % less speed.
- **Below 250 W**, you lose speed **and** energy per token: capping it further is useless.
- Generation speed follows the SM clock (≈ 0.035 to 0.039 tok/s per MHz): here, generation is compute-bound, not
  memory-bound.
- The card does not go above ≈ 309 W under load, even with a 350 W limit.

Limits of this measurement: one model, one workload, measurement noise (median CV 9 %, smallest detectable difference
≈ 10.5 %). The 300 W / 350 W difference (−9 %) was therefore **at the edge of what is detectable**: hence the
confirmation below.

### Confirmation (power-confirm, 15 repetitions per level)
Same model and workload; baseline 350 W; 95 % confidence intervals in brackets.

| Limit | Generation | Prefill | Time to 1st token | Mean power | Energy per token |
|---|---|---|---|---|---|
| **300 W** | **−6.8 %** [−12.5; −0.7] | −5.1 % | +3.7 % | −11.5 % | **−7.0 %** [−11.3; −2.5] |
| 250 W | −30.7 % [−35.0; −26.1] | −14.5 % | +14.9 % | −23.1 % | −0.8 % (not significant) |

All the 300 W differences are significant: about −7 % speed (the real difference is probably between 1 and 12 %), −7 %
energy per token. At 250 W speed drops by a third without any gain in energy per token: setting rejected.
Not noted at the time of the test: the state of the remote desktop (asked to be off; check it if the numbers are
compared with future measurements).

### Applying it permanently
```bash
lab gpu-limit install 300      # installs a systemd service (asks for sudo)
lab gpu-limit status           # current limit, bounds, service installed?
lab gpu-limit remove           # removes the service and restores the factory limit
```
The service runs `nvidia-smi -pm 1` then `-pl 300` at every boot. The benchmark **restores the limit it found** at the
end of each test, so it does not undo this setting.

## 1b. Cost of the context (context-scaling)

`qwen3.8:27b`, 300 W limit, `num_ctx` 65,536, 128 tokens generated, 5 repetitions per depth, production Ollama stopped
(so the task model was not loaded). Bench KV cache: **f16** according to `bench/labbench/config.py` (bench default; check
in `meta.json`), whereas production uses `q8_0`. These numbers come from `summary.csv`.

| Filled context | Generation (tok/s) | Prefill (tok/s) | Time to 1st token | Mean power | Share of time on GPU |
|---|---|---|---|---|---|
| 512 | 48.6 ± 4.2 | 896 | 1.5 s | 253 W | 100 % |
| 4,096 | 57.9 ± 5.2 | 1,225 | 3.6 s | 269 W | 100 % |
| 16,384 | 59.4 ± 2.7 | 1,204 | 13.4 s | 285 W | 100 % |
| 32,768 | 58.5 ± 2.6 | 1,126 | 27.4 s | 291 W | 100 % |
| 56,000 | 54.9 ± 4.4 | 1,023 | 50.8 s | 294 W | 100 % |

Reading:
- **The cost of a large context is paid at the first token**: about 0.9 ms per prompt token, i.e. ≈ 13 s for 16,000
  tokens, ≈ 27 s for 32,000, ≈ 51 s for 56,000 (prefill from 1,225 to 1,023 tok/s, down ≈ 16 %, narrow intervals).
- **Generation stays stable (≈ 55 to 59 tok/s) from 4,096 to 56,000 tokens**: the confidence intervals overlap. The
  drop at 56,000 (−7 % from the plateau) is not demonstrated. p95 inter-token latency: 51 → 56 ms.
- **The 512 point is suspicious** (generation 48.6 tok/s, power 253 W, SM clock 1,425 MHz, lower than the others, and a
  very noisy TTFT, CV 45 %): very short trials, GPU not yet at full speed. Do not use it as an "empty context speed"
  reference; the % differences in `comparisons.csv` are measured against it and are therefore misleading.
- **The model stays 100 % on the GPU with a 65,536-token context**, alone on the card. No thermal throttling (max
  63 °C); the card is capped by the power limit (300 W) almost all the time, which is the intended setting.
- Energy per token (7.6 → 110 J): it includes the prefill; it is not the efficiency of generation.

Limits: no comparison of `num_ctx` (the whole test is at 65,536, so the effect of the **window size** on VRAM and on
speed with an empty context is not measured, only the effect of the **amount of text** in the window); f16 cache, not
`q8_0`; a single model; 5 repetitions. Generation at 58 tok/s at 300 W, versus 50 tok/s measured in the `power-sweep`:
difference not explained (the remote desktop was active during the first test, state not noted for this one).

## 1c. Image generation: Qwen-Image-2.1 in ComfyUI

**Configuration**: ComfyUI 0.39.0, PyTorch 2.14.1+cu130, RTX 3090. Diffusion model `qwen-image-2.1-UC-BF16.gguf`
(14.2 GB, loaded by the *Unet Loader (GGUF)* node of the `leejet/ComfyUI-GGUF` fork), text encoder
`qwen3vl_8b_int8_convrot.safetensors` (9.35 GB), VAE `qwen_image_2.1_vae_bf16.safetensors`. Template settings:
1024×1024 (1:1, 1.0 megapixel), 25 steps, `cfg` 1.0, `euler` / `simple`, `refine_prompt` disabled. Files checked by
SHA256.

| Trial | Duration | Note |
|---|---|---|
| Template's default prompt (portrait) | **42.55 s** | first generation: loads the models |
| Test 1 (ramen alley) | 32.66 s | models already loaded |
| Test 2 (watchmaker) | 32.39 s | same |
| Test 3 (library) | 32.42 s | same |
| Test 3 (library) run again after unloading the models and the cache | 37.82 s | models reloaded |

- **Steady state: ≈ 32.5 s per image** (≈ 1.3 s per step, text encoding and VAE included: these times were not
  separated). Very stable: 32.39 to 32.66 s on three different prompts.
- **Loading cost: ≈ 5 s** (reload after unloading, 37.82 versus 32.42) **to ≈ 10 s** (very first image). The difference
  between these two values is not explained: the prompts differed, and it is not known exactly what "clearing the
  cache" cleared.
- **VRAM during generation**: 23,347 MiB used out of 24,576 MiB (95 %), of which 22,682 MiB for the ComfyUI process and
  ≈ 600 MiB for the desktop (gnome-shell, remote desktop). GPU at 100 %, 298 W out of 300 W, 53 °C, state P2. These
  22.7 GB are not the model's real need (14.2 GB): ComfyUI uses the available VRAM to keep data cached.
- **Observed quality** (4 images): very good fidelity on a long, descriptive prompt; short text in large characters
  correct; errors on the time of a clock, on small handwritten text and on a precise placement instruction ("the cat on
  the bicycle").
- **Setup**: `/root/.triton` was not writable for the container's user, which made the text encoder fail
  (`PermissionError`). Now fixed durably in `comfyui/docker-compose.yml` (`TRITON_CACHE_DIR`).

Details, examples and pitfalls in [image-generation.md](image-generation.md).

**Not measured**: isolated per-step duration; resolutions above 1 megapixel; a different number of steps; Q8_0 and INT8
compared with BF16 (speed, quality, VRAM); effect of the remote desktop on available VRAM; spread over several seeds;
mean power over a full image.

## 2. Ollama settings and what they change

| Setting (`ai-stack/.env`) | Effect | How to measure it |
|---|---|---|
| `OLLAMA_CONTEXT_LENGTH` | Default context window size. Larger = more VRAM (KV cache) and a longer prefill | `lab bench context-scaling` |
| `OLLAMA_KV_CACHE_TYPE` | `f16` (most precise), `q8_0` (≈ half the cache memory), `q4_0` (≈ a quarter; quality to watch) | `lab bench kv-cache` (speed + finding a piece of information) and `kv-quality` |
| `OLLAMA_FLASH_ATTENTION` | Optimised attention; required to quantise the KV cache | `kv-cache` (`flash_attention` factor) |
| `OLLAMA_NUM_PARALLEL` | Requests served at the same time. Each slot multiplies the KV cache | `lab bench concurrency` |
| `OLLAMA_KEEP_ALIVE` | How long the model stays in VRAM. Avoids reloads (loading 17 GB takes many seconds) | look at `load_s` in `runs.csv` |
| `OLLAMA_MAX_LOADED_MODELS` | Number of models in VRAM at the same time (2 with a task model) | `ollama ps` |

The orders of magnitude of the KV cache (f16 > q8_0 > q4_0) are properties of the format; **the losses of speed and
quality are only partly known: `kv-cache` and `kv-decode` measured memory, speed and the needle; `kv-quality` showed no
difference but discriminates poorly (3 correct calculations out of 12)**.

## 3. Procedure (in this order)

1. **Clean environment**: stop the remote desktop (`lab desktop off`), close browsers and heavy graphical
   applications. Check `lab status`: the GPU must be in `P8` at idle (≈ 20 W).
2. `lab bench quick-smoke`: makes sure everything works (5 min).
3. `lab bench power-confirm`: confirms 300 W with 15 repetitions (≈ 10 min).
4. `lab bench context-scaling`: cost of the context, to choose `OLLAMA_CONTEXT_LENGTH` (see §1b).
5. `lab bench kv-cache`, then `lab bench kv-decode`, `lab bench kv-quality` and `lab bench kv-quality-easy` (150 easy
   calculations): choose f16 or q8_0 knowingly. Then `lab bench ctx-window` (window size × cache type: reserved VRAM
   and limit before spilling over).
6. `lab bench concurrency`: only if you intend to serve several requests in parallel (n8n + Open WebUI + agents).
7. After each change in `ai-stack/.env`: `cd ai-stack && docker compose up -d`, then check
   `docker exec ollama ollama ps`: the model must stay **100 % GPU**.

Durations given in `bench/README.md`: estimates, not measured except where stated.

## 4. Decision log (reference machine)

| Date | Decision | Evidence |
|---|---|---|
| 2026-10-15 | Target power limit: 300 W | `power-sweep` (see §1) |
| 2026-10-15 | Remote desktop off by default (−100 W at idle) | `remote-desktop-gpu.md` |
| 2026-10-16 | **300 W confirmed** and installed permanently (`lab gpu-limit install 300`) | `power-confirm`, 15 repetitions: −7 % speed, −7 % energy/token, −11.5 % mean power (see §1) |
| 2026-10-18 | `OLLAMA_CONTEXT_LENGTH` **unchanged** (32,768): no measurement justifies changing it; 65,536 remains possible as a preset | `context-scaling` (§1b): 100 % GPU at 65,536, stable generation, cost = time to first token |
| 2026-10-18 | `OLLAMA_KV_CACHE_TYPE` **unchanged** (`q8_0`), to be confirmed | `kv-cache`: VRAM ≈ 20,643 / 19,760 / 19,250 MiB (f16 / q8_0 / q4_0), prefill and TTFT identical within < 1 %, needle 100 % everywhere; decoding **invalid** (4 to 7 tokens); `kv-decode`: `f16` 58.6, `q8_0` 55.7 (5 measurements out of 6), `q4_0` 55.4 tok/s, `f16`/`q8_0` difference ≈ 5 % not demonstrated; VRAM reproducible; `kv-quality`: 30 (`f16`), 29 (`q8_0`), 30 (`q4_0`) correct answers out of 120, no difference but a poorly discriminating test (3 correct calculations out of 12) |
| 2026-10-18 | Context window: **32,768 by default unchanged**; 65,536 possible in `q8_0` with the small model; 98,304 not recommended | `ctx-window`: VRAM `q8_0` 19,045 / 19,065 / 19,769 / 21,147 / 22,555 MiB (8,192 → 98,304), `f16` 22,854 at 65,536 then **spill-over at 98,304** (81 % on GPU, decoding 24 tok/s); no detectable speed loss up to 65,536 |
| 2026-10-19 | No setting changed: Ollama's prefix cache already works (the identical start of a prompt is read 10 to 23 times faster) | `prefix-cache` (f16): warm TTFT 0.56 / 0.63 / 0.81 s versus cold 1.4 / 6.5 / 18.9 s for ≈ 950 / 7,400 / 21,500 shared tokens. For agents: keep the start of the prompt stable |
| 2026-10-19 | `lab update`: 6 images updated (including `ollama`), plus MinIO (Langfuse, not recorded for `lab rollback`, fixed) | `kv-decode` run again after the update: `f16` 57.6 tok/s (before 58.6), `q8_0` 54.7 and `q4_0` 56.3 apart from one measurement at ≈ 23 tok/s in each; identical VRAM; no visible regression; `q8_0` kept |
| 2026-10-19 | `OLLAMA_KV_CACHE_TYPE` **`q8_0` confirmed** (choice kept) | `kv-quality-easy`: 147 (`f16`), 147-148 (`q8_0`), 148-149 (`q4_0`) correct answers out of 150, no visible loss; a test that puts little load on the cache (≈ 65 tokens per question); `q4_0` only saves 0.5 GiB more |
| 2026-10-19 | `OLLAMA_NUM_PARALLEL` **unchanged (1)** | `concurrency`: total throughput ≈ 36-38 tok/s whatever the number of clients (1, 2, 4) and `NUM_PARALLEL` (1, 2, 4); first token ≈ 1.1 / 2.9 / 6.4 s for 1 / 2 / 4 clients; identical VRAM: requests are handled one after the other; cause: Ollama ignores `NUM_PARALLEL` for `qwen35` (confirmed by `server-logs.txt`) |
| 2026-10-21 | Images: Qwen-Image-2.1 `UC-BF16.gguf` tried in ComfyUI | ≈ 32.5 s per image at 1024×1024 / 25 steps (models loaded), VRAM 23.3 GiB out of 24; see §1c |

Add a line for each settings change: date, decision, measurement that justifies it.

## 5. What is not measured

- `prefix-cache` and `concurrency`: measured in `f16` only; for `concurrency`, `NUM_PARALLEL` is ignored by Ollama for
  the `qwen35` architecture (server log: "does not currently support parallel requests", `-np 1`). Do not choose these
  settings on numbers that come from elsewhere.
- The 300 W limit is only confirmed for this model and this workload (generation, 2,048 tokens of context).
- The effect of the remote desktop on the noise of the `power-sweep` (assumed, not quantified).
