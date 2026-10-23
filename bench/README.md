# Benchmark bench (labbench)

Measure in a **reproducible, quantified** way: model speed, effect of the KV cache, of the context, of parallelism, and
the **performance loss when the GPU power is capped**. Every result comes with a confidence interval and validity
warnings.

```bash
./7-bench.sh check
./7-bench.sh run quick-smoke --model qwen3.8:27b       # ~5 min, checks that everything works
./7-bench.sh run power-sweep --model qwen3.8:27b       # ~1 h
```

Results: `bench/results/<experiment>-<date>/` → `report.html` (open it in a browser), `runs.csv` (one line per
measurement), `telemetry.csv` (GPU at 10 Hz), `summary.csv`, `comparisons.csv`, `meta.json`.

## Provided experiments (`bench/experiments/*.yaml`)

| Name | Question | Indicative duration* |
|---|---|---|
| `quick-smoke` | Does it work? (300 W vs 200 W, 3 repetitions) | ~5 min |
| `power-sweep` | How many tok/s, J/token and °C are lost at 350/300/250/220/200/180/150 W? | ~1 h |
| `context-scaling` | Cost of prefill and generation depending on the context size (512 → 56,000 tokens) | ~1 h |
| `ctx-window` | Window size (`num_ctx` 8,192 → 98,304) × KV cache (`f16`/`q8_0`): reserved VRAM, speed with an empty context, limit before spilling over to the CPU | ~1 h* |
| `kv-cache` | KV cache f16 / q8_0 / q4_0: VRAM, prefill and ability to find a piece of information in 24,000 tokens (needle). **Its decoding speed is invalid** (4 to 7 tokens generated): see `kv-decode` | 22 min (measured) |
| `kv-decode` | Decoding speed and VRAM per KV cache type (f16 / q8_0 / q4_0), context filled with 24,000 characters, 128 tokens generated | 9 min (measured) |
| `kv-quality-easy` | Quality on 150 easy calculations (same set for the 3 caches): detects a loss of at least ≈ 5 points; puts little load on the cache (questions of ≈ 65 tokens) | ≈ 9 min (measured) |
| `kv-quality` | Quality on 12 calculations depending on the KV cache type (not very discriminating: the model only gets 3 out of 12 right) | ~30 min* |
| `prefix-cache` | TTFT gain when a long prompt beginning is reused | ≈ 4 min (measured) |
| `concurrency` | `OLLAMA_NUM_PARALLEL` × number of clients: aggregate throughput vs latency (also records `server-logs.txt`) | ≈ 8 min (measured) |

\* estimates, not measured on your machine. `--dry-run` shows the plan, `--reps N` changes the number of repetitions.

Writing your own experiment = copying a YAML file. Possible factors: `power_limit_w`, `kv_cache_type`,
`flash_attention`, `num_parallel`, `num_ctx`, `ctx_depth`, `gen_tokens`, `clients`, `needle_depth`, `think`. The grid
is **factorial** (all combinations of the lists). Workloads (`workload`): `mixed`, `needle`, `prefix_cache`,
`concurrency`, `arith`, `arith_easy`.

## What is measured

- **Generation** (tok/s), **prefill** (tok/s), **TTFT** (time to first token), **inter-token latency** (p50/p95/p99):
  durations reported by Ollama + client-side timing while streaming.
- **GPU**: power, temperature, SM/memory clocks, utilisation, VRAM, throttle reasons (power limit, thermal, hardware
  slowdown), sampled at 10 Hz.
- **Energy**: NVML hardware counter (exact), hence J/token and tok/J. Includes prefill and idle consumption.
- **Placement**: share of the model in VRAM according to `/api/ps` (detects a spill-over to the CPU).
- **Quality** (`needle`, `arith`): success rate with a Wilson interval.

## Method (why the numbers can be trusted… or not)

1. **Randomised plan**: the order of the measurements is shuffled (fixed, recorded seed) so that a thermal drift is not
   mistaken for a factor. Only "server" factors (KV cache, flash attention, parallelism) are grouped in blocks, because
   each block restarts the test container.
2. **Repetitions** (5 by default, 7 for `power-sweep`) + an uncounted warm-up before each block.
3. **Cool-down**: we wait until the GPU is back under `cooldown.target_c` before each measurement.
4. **No cache cheating**: every prompt starts with a unique identifier, otherwise Ollama reuses the prefix cache of a
   previous measurement (except in `prefix_cache`, whose subject it is).
5. **Statistics**: mean ± 95 % CI (Student); variation from the baseline in % with a bootstrap CI; a difference is
   marked **significant** (`*`, green background) only if the CI excludes 0. The report also gives the CV and the
   **smallest detectable difference**: below it, a difference is noise.
6. **Automatic warnings**: few repetitions, high noise (CV > 5 %), drift over time (Spearman), thermal or hardware
   throttling, model partly outside VRAM.
7. **Resume**: if the test is interrupted, run again with `--resume bench/results/<folder>`: the measurements already
   done are kept. The original power limit is restored at the end, even on error.

## Limits to know

- **Isolation**: during a test, nothing else may use the GPU. The script stops the production Ollama; stop ComfyUI and
  Hermes too. The report flags high noise, but cannot guess the cause.
- **Room temperature, airflow**: not controlled; they influence thermal throttling. Write them down.
- **Quality**: `needle` and `arith` are small tests (a few dozen trials): they detect a marked degradation, not a 1 %
  loss. For a rigorous quality measurement (perplexity on a corpus), `llama-perplexity` from llama.cpp would have to be
  added — not done here.
- **A "thinking" model** (like qwen3.8): `think: false` by default to measure raw speed. With `think: true`,
  `gen_tokens` must be large, because the reasoning uses tokens.
- **Power limit**: set with `sudo nvidia-smi -pl`. The driver may round it; the real value is read back and recorded
  (`power_limit_actual_w`).
- **Ollama** does not expose every llama.cpp setting (e.g. `-ctv` separate from `-ctk`): the K and V cache type is
  shared.
- The numbers hold for **this machine, this model, this version of Ollama** (recorded in `meta.json`).

## Tests of the bench itself

`python3 bench/tests/run_tests.py`: tests with a fake Ollama server and a fake GPU (no hardware needed). They check the
logic (plan, resume, calculations, detection of a simulated loss), **not** the real behaviour of your GPU.

## Delivering a new version to AiBeast from the Windows PC

`windows\outils\Deployer-sur-AiBeast.bat` (double-click, VPN connected, SSH key loaded) sends `ai-lab.tar.gz` with
`scp`, checks the size, **refuses to continue if a benchmark is running**, backs up `bench`, `docs`, `windows`,
`scripts` and `lab` to `~/avant-YYYYMMDD-HHMM.tgz`, extracts into `~/Documents`, then compares every file of the archive
with the disk. Tested on the AiBeast side only (bash script tried in a dummy folder).
