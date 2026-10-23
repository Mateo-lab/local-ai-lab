# Understanding the measurements: what to test, why, and how to read the results

This document explains **each setting the benchmark bench (`lab bench`) measures**: what it is, why it is worth testing,
how to read the result, and what the reference machine gave. It ends with a glossary.

The reference machine's numbers are in [performance.md](performance.md); the bench's user guide is in
[`bench/README.md`](../bench/README.md). Here: the "why" and the "how to read".

## 1. Why measure instead of guessing

A setting that "looks good" can cost speed, memory or quality without it showing in daily use. Real example: the 300 W
power limit is advertised as "lossless" everywhere; on the reference card, it costs about 7 % of generation speed (and
saves 7 % of energy per token). It is a good compromise, but it is a **compromise**, and only measurement says by how
much.

House rule: **a setting is only changed when a measurement justifies it, and the decision is written down** in the log
of [performance.md](performance.md) §4.

## 2. The map: one setting, one question, one experiment

| Setting | The question | Experiment | Decision at stake | Status |
|---|---|---|---|---|
| GPU power limit | How much speed is lost by capping the card? | `power-sweep`, `power-confirm` | Which limit to install (`lab gpu-limit`) | **Measured**: 300 W |
| Amount of text in the context | How much does a long document cost? | `context-scaling` | Value of `OLLAMA_CONTEXT_LENGTH`, waiting time to expect | **Measured** |
| Context window size (`num_ctx`) | How much does it cost to **reserve** a large window, even empty? Where is the card's limit? | `ctx-window` | Default window size and per preset; VRAM margin | Measured (see §3.2b) |
| KV cache type (`f16`, `q8_0`, `q4_0`) | How much memory is saved, for what loss of speed or accuracy? | `kv-cache` | Value of `OLLAMA_KV_CACHE_TYPE` | Measured (decoding invalid, see §3.3) |
| Quality with a quantised KV cache | Does quantisation damage the answers? | `kv-quality` | Keep `q8_0` or give up `q4_0` | Measured (no visible loss, weak tests, see §3.4) |
| Prefix cache | Is time saved when the start of a prompt repeats? | `prefix-cache` | How to write the agents' prompts | Measured (see §3.5) |
| Parallelism | Can several requests be served at the same time? | `concurrency` | Value of `OLLAMA_NUM_PARALLEL` | Measured (see §3.6) |

## 3. The settings, one by one

### 3.1 GPU power limit

**What it is.** A cap in watts the card does not exceed (`nvidia-smi -pl`). The factory sets the RTX 3090 to 350 W.

**Why test it.** Fewer watts means less heat, less noise, less consumption. But the card lowers its clock to respect the
cap, so it computes more slowly. The point is to know **from where the speed loss is no longer compensated by the energy
saved**.

**What is measured.** Generation speed (tok/s), energy per token (J/token), mean power, GPU clock.

**How to read it.**
- Compare the speed **and** the energy per token. A lower cap is only interesting if the energy per token drops too.
- Below a certain threshold, both get worse: the card runs so slowly that the "fixed" energy (memory, fans, idle) weighs
  more per token. Capping it further is then useless.

**Result on the reference machine** (`qwen3.8:27b`, 2,048 tokens of context): 300 W gives about −7 % speed, −7 % energy
per token, −11.5 % mean power; 250 W loses a third of the speed without any energy gain. **300 W is installed
permanently.**

### 3.2 The context: how much text the machine "keeps in mind"

**What it is.** The context window is the amount of text (conversation, document, instructions) the model sees at the
same time, counted in tokens. `OLLAMA_CONTEXT_LENGTH` sets the default size; an Open WebUI preset can change it
(`num_ctx`).

**Why test it.** A large context makes it possible to analyse a long document, but it has two costs: **memory** (the KV
cache, see §3.3) and **time** (the model must "read" all the text before answering: that is the prefill).

**What is measured.** The context is filled to 512, 4,096, 16,384, 32,768 and 56,000 tokens and we look at: the delay
before the first word (TTFT), the reading speed (prefill), the generation speed, and whether the model stays entirely on
the GPU.

**How to read it.**
- **TTFT**: this is the waiting time you feel. It grows roughly in proportion to the text to read.
- **Generation speed**: if it stays stable as the context grows, a large context does not slow down the following words.
- **Share of time on the GPU** (`gpu_frac`): must stay at 100 %. If it drops, part of the model spills over to the CPU
  and everything becomes much slower.

**Result on the reference machine.** TTFT: 3.6 s at 4,096 tokens, 13.4 s at 16,384, 27.4 s at 32,768, 50.8 s at 56,000
(≈ 0.9 ms per prompt token). Stable generation (≈ 55 to 59 tok/s). 100 % GPU up to a 65,536 context, alone on the card.
**Decision: `OLLAMA_CONTEXT_LENGTH` unchanged (32,768).**

**Pitfall.** This test measures the *amount of text in the window*, not the *size of the window*: the whole series is at
`num_ctx` 65,536. The effect of the window size on memory and on speed with an empty context was not compared here (see
§3.2b).

### 3.2b The window size (not to be confused with how full it is)

**What it is.** `num_ctx` is the size of the **reserved** window; the fill is the text actually in it. The KV cache memory
(§3.3) is sized on the window, not on the text, according to how Ollama is understood to work (this is one of the things
this test establishes). A 65,536 window for a 500-token conversation would therefore cost the same VRAM as a full window.

**Why test it.** `context-scaling` measured the cost of *filling* a fixed window. It says nothing about the cost of the
*size*: how much VRAM going from 32,768 to 65,536 takes, what margin remains for the task model or ComfyUI, and from what
size the model spills over to the CPU.

**What is measured (`ctx-window`).** Five sizes (8,192, 16,384, 32,768, 65,536, 98,304) × two cache types (`f16`,
`q8_0`), with a short 1,024-token prompt to measure only the effect of the reservation: VRAM used on the card
(`peak_mem_used_mb`), share of the model in VRAM (`gpu_frac`), generation speed, TTFT, window size actually applied
(`ctx_effective` in `runs.csv`).

**How to read it.**
- **VRAM as a function of `num_ctx`**: if it grows in a straight line with the size, each 16,384 tokens of window cost a
  fixed amount; you deduce the margin available for a given window. Compare `f16` and `q8_0`: the difference is the gain
  of the compressed cache.
- **`gpu_frac` < 100 %** at a given size: the model no longer fits entirely on the card. This is the practical limit,
  not a bench error.
- **`ctx_effective` lower than `num_ctx`**: the model caps its window at its maximum. Beyond it, asking for more is
  useless.
- **Generation speed and TTFT with an empty context**: if they barely move with the size, a large window only costs
  memory.

**Pitfalls.**
- `peak_mem_used_mb` is the VRAM of **the whole card**: if something else uses it (ComfyUI, the remote desktop, another
  model), the number is skewed. Isolate the card as for the other tests.
- The bench reloads the model at each change of size (the test is grouped by size to limit reloads).
- To run **after** `kv-cache`: the chosen cache type determines the row that matters for your production.

**Result on the reference machine (`ctx-window`, 40 measurements, 4 repetitions per condition, short prompt, 128 tokens
generated, 300 W).**

VRAM used on the card (peak, MiB; 24,576 MiB card; the bench runs alone, production stopped):

| `num_ctx` | `f16` | `q8_0` | Model on the GPU |
|---|---|---|---|
| 8,192 | 19,284 | 19,045 | 100 % |
| 16,384 | 19,524 | 19,065 | 100 % |
| 32,768 | 20,644 | 19,769 | 100 % |
| 65,536 | 22,854 | 21,147 | 100 % |
| 98,304 | 22,682 (**spill-over**) | 22,555 | **`f16`: 81 %**; `q8_0`: 100 % |

- **The growth is not linear:** for `q8_0`, going from 8,192 to 16,384 only costs 20 MiB, then +704 (→ 32,768), +1,378
  (→ 65,536), +1,408 (→ 98,304). For `f16`: +240, +1,120, +2,210. Do not extrapolate from two points.
- **`f16` spills over at 98,304:** 19 % of the model goes to the CPU (the measured VRAM *drops* because layers left),
  decoding falls from ≈ 50 to **24 tok/s**, prefill from ≈ 1,070 to 785 tok/s, TTFT rises to 1.45 s. Same cache type: at
  65,536 `f16` already takes 22.9 GB; with the small task model (≈ 1.7 GiB) it would no longer fit.
- **`q8_0` fits at 98,304** (22,555 MiB, i.e. ≈ 2.0 GiB of margin, speed unchanged), **but alone**: with the small task
  model loaded, the margin would disappear (not measured). The estimate made before the measurement (≈ 21.7 GB) was about
  0.9 GB too low.
- **Speed:** up to 65,536, decoding stays between 48 and 54 tok/s for both caches, differences within the error margins
  (4 repetitions): reserving a large window costs no detectable speed, only memory, as long as everything fits. TTFT is
  0.97 s at 8,192 then ≈ 1.11 to 1.14 s from 16,384 on and flat afterwards (unknown cause, 0.14 s difference).
- The decoding in this experiment (≈ 50 tok/s) is lower than in `kv-decode` (≈ 56-59): different protocols (short prompt,
  4 repetitions, lower GPU clocks: 1,410-1,460 MHz versus ≈ 1,550). Do not compare the two.

**Consequences for the settings.** `OLLAMA_CONTEXT_LENGTH` stays at 32,768. A preset at 65,536 is possible in `q8_0` with
the small task model (22,620 MiB measured, §1 of `open-webui.md`); not in `f16`. 98,304: `q8_0` only, without the small
model, and without margin: not recommended.

### 3.3 The KV cache and its quantisation

**What it is.** To produce each new word, the model consults intermediate results of everything that comes before (the
"keys" and "values" of attention, hence KV). Rather than recompute them, it keeps them in video memory: this is the
**KV cache**. Its size grows with the context. It can be stored at full precision (`f16`) or compressed (`q8_0`, about
half the memory; `q4_0`, about a quarter). The compression of `q4_0` and `q8_0` is called **quantisation**. **Flash
attention** (`OLLAMA_FLASH_ATTENTION`) is an optimised way of computing attention, required to quantise the cache.

**Why test it.** The card has 24 GB of VRAM and the big model takes a large part of it. A smaller cache frees room (for
the task model, for a larger context, for ComfyUI next to it). In return, it can slow down or degrade the answers: how
much depends on the model, which is why it is measured on **yours**.

**What is measured.** For `f16`, `q8_0` and `q4_0`: generation and prefill speed, VRAM, and a "needle" test: a piece of
information is hidden at 10 %, 50 % or 90 % of a 24,000-token text and the model is asked to find it (success rate with
its uncertainty interval).

**How to read it.**
- If `q8_0` is not slower than `f16` **and** finds the needle as often, it is preferable (same result, less memory).
  This is a reading proposal, not a demonstrated rule.
- `q4_0` is only justified if it loses nothing visible; the strongest quantisation is the one most at risk.
- A success rate that drops **mostly for a precise position** of the needle (for example 50 %, in the middle) is a sign
  that the compression hampers retrieving information from a long text.

**Result on the reference machine (`kv-cache`, 54 measurements, 22 min, context 32,768 filled to ≈ 21,700 tokens,
300 W).**

| Cache | VRAM used on the card (peak) | Prefill (tok/s) | TTFT (s) | Needle found |
|---|---|---|---|---|
| `f16` | ≈ 20,643 MiB | 1,170 | 19.44 | 100 % |
| `q8_0` (production) | ≈ 19,753-19,771 MiB | 1,160 | 19.35 | 100 % |
| `q4_0` | ≈ 19,241-19,259 MiB | 1,162 | 19.18 | 100 % |

- **Memory:** `q8_0` saves ≈ 0.9 GiB of VRAM compared with `f16`, `q4_0` ≈ 0.5 GiB more (values read in `runs.csv`,
  whole card, 595 MiB already used at idle). The f16 cache of 32,768 tokens therefore weighs ≈ 1.9 GiB on this model
  (extrapolated from these differences, not measured directly).
- **Prefill and TTFT:** `f16` is < 1 % faster: of no practical interest.
- **Accuracy:** the needle is found everywhere, `q4_0` included. A weak test (a single fact): the verdict comes from
  `kv-quality`.
- **Decoding: do not use it.** The model only generated 4 to 7 tokens per request (the answer is a 6-character code); the
  speed computed on so few tokens depends on the number of tokens (≈ 69 tok/s for 4, 85-90 for 5, 100-109 for 6, ≈ 61
  for 7), not on the cache. At an equal number of tokens (5), the medians are `f16` ≈ 90, `q8_0` ≈ 86, `q4_0` ≈ 85
  tok/s: a trend (≈ 5 % for `f16`), not a proof, and the blocks ran one after the other (`q4_0`, `f16`, `q8_0`). The
  clean measurement is the `kv-decode` experiment (below).
- **J/token: meaningless here** (≈ 5,000 J for the whole request, prefill included, divided by 5 tokens). Two `f16`
  measurements (10 % depth) have an inconsistent energy counter (707 and 3,763 J) with peaks at 365-380 W.

**Result on the reference machine (`kv-decode`, 18 measurements, 9 min, 128 tokens generated per request, context
≈ 22,000 tokens, 300 W).**

| Cache | Mean decoding (tok/s) | Median | The 6 measurements (tok/s) | VRAM (MiB) |
|---|---|---|---|---|
| `f16` | 58.6 ± 3.0 | 59.0 | 54.4 to 62.5 | 20,643 |
| `q8_0` | 50.4 ± 13.8 (**55.7** without the 24.1 measurement) | 54.9 | 24.1; 51.4; 53.8; 56.1; 57.2; 59.8 | 19,771 |
| `q4_0` | 55.4 ± 2.4 | 55.0 | 53.2 to 58.9 | 19,263 |

- **Outlier:** one `q8_0` measurement (the 2nd of the block) lasted 25.1 s instead of 21-22 s and decoded at 24 tok/s,
  with a peak at 305 W (above the 300 W limit). Unknown cause (one-off hiccup). Without it, `q8_0` ≈ 55.7 tok/s
  (5 measurements).
- **Speed:** `f16` ≈ 5 % faster than `q8_0` (58.6 versus 55.7 tok/s), `q4_0` ≈ `q8_0` (55.4). The same order of
  magnitude (+5 % for `f16`) had appeared at an equal number of tokens in `kv-cache`. **It is not statistically
  established** (the 3 tok/s difference is of the same order as the spread between measurements, 6 measurements per
  cache, blocks run one after the other).
- **VRAM:** identical to `kv-cache` to the last MiB (reproducible): `q8_0` saves 872 MiB, `q4_0` 508 MiB more.
- **J/token (42 to 50):** ≈ 19.5 s of prefill for ≈ 2.2 s of decoding; the energy of decoding alone is around 5 J/token
  (288 W ÷ 58 tok/s). Do not compare with other experiments.

**Same test after an Ollama update (`kv-decode`, the day after, following `lab update`, 18 measurements).**

| Cache | Mean decoding (tok/s) | Without the outlier | The 6 measurements (tok/s) | VRAM (MiB) |
|---|---|---|---|---|
| `f16` | 57.6 ± 2.6 | (none) 57.6 | 53.7 to 60.3 | 20,642 |
| `q8_0` | 49.6 ± 13.5 | 54.7 | 23.9; 51.0; 52.3; 55.9; 55.9; 58.5 | 19,771 |
| `q4_0` | 50.7 ± 14.3 | 56.3 | 23.0; 54.0; 55.5; 56.8; 56.8; 58.3 | 19,259 |

- **No visible regression:** `f16` 57.6 versus 58.6 before (within the spread), VRAM identical to a few MiB. This test does
  not say whether the Ollama image really changed engine version (the version is not in the files received).
- **Outliers:** `q8_0` and `q4_0` each have one measurement at ≈ 23 tok/s (the 5th of their block), 3 s longer than the
  others and with a lower mean power. Already seen once for `q8_0` the day before, never for `f16` (3 times out of 24
  quantised measurements, 0 out of 12 in `f16`). Unknown cause; there is no proof that the quantised cache is
  responsible, and 12 measurements in `f16` are not enough to rule it out.
- **Conclusion unchanged:** `f16` ≈ 3 to 5 % faster than the quantised caches apart from outliers, a difference of the
  same order as the spread; `q8_0` stays in production for ≈ 0.9 GiB of VRAM.
- **About the `itl_p50_ms` column:** ≈ 0.018 ms, hence unusable. The server log shows the engine starts with
  `--spec-type draft-mtp` (speculative decoding: several tokens validated at once). The effect of this mode was not
  measured; only read `decode_tps` and `itl_p95_ms`.
- **Why quantisation saves little:** the log shows that only 16 of the 64 layers have a KV cache (`f16`: 2,048 MiB at a
  32,768 context, `q8_0`: 1,088, `q4_0`: 576); the rest is a fixed recurrent state of 748 MiB.

**Provisional decision:** `q8_0` stays in production: ≈ 0.9 GiB of VRAM saved compared with `f16` for a decoding loss of
about 5 % (≈ 3 tok/s, not demonstrated), no visible loss on the needle. `q4_0` is no faster than `q8_0` and only saves
0.5 GiB more: only to consider after `kv-quality`. If VRAM is never the limit, `f16` remains defensible.

### 3.4 Quality with a quantised KV cache

**What it is.** An accuracy test complementary to the needle: 12 arithmetic calculations per measurement, 10
repetitions, for each cache type, with the model's reasoning disabled.

**Why test it.** A fast but wrong answer is useless. This test detects a **marked** degradation.

**How to read it.** Compare the success rate between `f16`, `q8_0` and `q4_0` (with the Wilson intervals). If the
intervals overlap, **you cannot say that one is better**: it is noise.

**Result on the reference machine (`kv-quality-easy`, 150 easy calculations, 2 repetitions per cache, ≈ 9 min, context
8,192).**

| Cache | Correct answers (repetition 1 / 2) | Mean rate | VRAM (MiB) |
|---|---|---|---|
| `f16` | 147 / 147 out of 150 | 98.0 % | 19,287 |
| `q8_0` | 148 / 147 | 98.3 % | 19,049 |
| `q4_0` | 149 / 148 | 99.0 % | 18,921 |

- **No visible loss:** the three caches are at 98-99 %, the maximum difference is 2 questions out of 150, which is noise
  (`q4_0` even comes first, without meaning it is better). For 147 successes out of 150, the 95 % interval goes from
  about 94 % to 99 %: the test would only see a loss of at least ≈ 5 points.
- **But it puts little load on the cache:** each question is only ≈ 65 tokens; quantisation has very little material to
  damage. This test mostly says that the model works normally with a quantised cache, not that `q4_0` holds on long
  texts. For long contexts, only the needle at ≈ 22,000 tokens (100 % for all three) answers, and it is a weak test.
- **Repetitions:** at zero temperature identical answers were expected; `q8_0` and `q4_0` differ by one question between
  the two repetitions (a random identifier placed at the start of each prompt is enough to slightly change the
  calculations).
- **Conclusion:** `q4_0` showed no degradation in the three tests (long needle, 12 hard calculations, 150 easy
  calculations), but these tests are weak and it only saves 0.5 GiB more than `q8_0`. There is no reason to take that
  risk: `q8_0` remains the choice.

**Limits.** 12 calculations is little: it sees a collapse, not a 1 % loss. A rigorous quality measurement would require a
text corpus and a perplexity measurement (not done here).

**Result on the reference machine (`kv-quality`, 12 calculations × 10 repetitions × 3 caches, context 8,192).**

| Cache | Mean success rate | Variability | VRAM (MiB) |
|---|---|---|---|
| `f16` | 25.0 % (3 calculations out of 12, **identical in all 10 repetitions**) | 0 | 19,289 |
| `q8_0` | 24.2 % (29 correct answers out of 120) | 10.9 % | 19,049 |
| `q4_0` | 25.0 % (30 out of 120) | 22 % | 18,926 |

- **No detectable difference** between the three caches: 29, 30 and 30 correct answers out of 120.
- **But the test is not very informative.** (1) The model, without reasoning, only gets 3 calculations out of 12 right
  (3-digit × 2-digit multiplication + 3 digits, direct answer): with such a low baseline, a quality degradation would be
  hard to see. (2) The 12 questions and the seed are fixed and the temperature is zero: `f16` gives exactly the same
  answers at every repetition, so the 10 repetitions are worth **a single measurement**. (3) 12 questions: a difference
  of 1 or 2 answers is not significant.
- **Cautious conclusion:** this test **does not prove** that `q4_0` is safe; it only shows that there is no visible
  collapse on this test. To decide, easier questions (baseline close to 100 %) and more of them would be needed. That is
  the **`kv-quality-easy`** experiment (150 easy calculations, same questions for the three caches, 6 measurements):
  result above.
- **Speed and energy of this experiment: to ignore** (answers of a few tokens, see §4.3b).
- **VRAM at an 8,192 context:** `f16` 19,289, `q8_0` 19,049, `q4_0` 18,926 MiB. A "per-token" cache size had been
  deduced from these assuming linear growth; **`ctx-window` showed that this is wrong** (see §3.2b: the growth is not
  linear). Do not keep that extrapolation.

### 3.5 The prefix cache

**What it is.** When a new request starts exactly like the previous one (same instructions, same start of conversation),
Ollama can reuse the work already done on that start instead of reading it again.

**Why test it.** For agents (Hermes, OpenClaw), which send a long identical start at every turn (system instructions,
tools, history), the time saved can be large. Conversely, a start that changes every time cancels the benefit.

**What is measured.** TTFT when the start is already known, with 1,024, 8,192 and 24,000 tokens of shared prefix.

**How to read it.** A TTFT that drops when the prefix is reused means that **the order of the prompt's elements
matters**: put what does not change **at the start**, what changes at the end.

**Result on the reference machine (`prefix-cache`, 18 measurements, ≈ 4 min, KV cache in `f16`: the bench default, not
the production value `q8_0`).** Each measurement sends two requests sharing the same long start: the 1st is "cold", the
2nd "warm".

| Shared start (real tokens) | Cold TTFT | Warm TTFT | Gain |
|---|---|---|---|
| ≈ 950 | 1.39 s (very variable: 1.1 to 1.8) | 0.56-0.58 s | × 2.5 (± 0.6) |
| ≈ 7,400 | 6.52 s | 0.62-0.64 s | × 10.3 (± 0.5) |
| ≈ 21,500 | 18.87 s | 0.81 s | **× 23.3** (± 0.4) |

- **The gain grows with the length of the shared start** because the cost of a warm request stays almost fixed (0.56 s
  to 0.81 s) while that of a cold request grows with the text. For an agent sending ≈ 20,000 identical tokens at every
  turn, the first token arrives in less than a second instead of 19 s.
- **Condition:** the start must be **identical character for character** and at the **start** of the prompt (a date, an
  identifier or a timestamp placed first cancels the gain), and the model must stay loaded (30 min by default here).
- **Not measured:** with the production `q8_0` cache, with several conversations in parallel (see `concurrency`), and in
  the real clients (Hermes, OpenClaw, Open WebUI): it is not known whether they keep their start stable.
- **Bench defect fixed:** the "share of the prefix reused" column (`cache_reuse_frac`) was 0 everywhere because Ollama
  reports the number of tokens of the **complete** prompt even when it reuses a large part of it. The calculation is now
  based on the prompt reading times (18.4 s versus 0.73 s, i.e. 96 % avoided at 21,500 tokens). For the run already done,
  ignore this column and read `cold_prompt_eval_s` / `warm_prompt_eval_s` in `runs.csv`. The fix is only verified by the
  test suite, not on the GPU.
- Decoding speed and J/token of this experiment: not applicable (32 tokens, energy dominated by reading the prompt).

### 3.6 Parallelism

**What it is.** `OLLAMA_NUM_PARALLEL` sets how many requests the same model handles at the same time. Each extra "slot"
multiplies the KV cache.

**Why test it.** n8n, Open WebUI and the agents can ask for something simultaneously. You need to know whether
parallelism increases the total work per second (the **aggregate throughput**) or whether everyone just waits longer.

**What is measured.** `NUM_PARALLEL` of 1, 2 and 4 with 1, 2 and 4 simultaneous clients: total throughput and latency per
client.

**How to read it.** The right setting is the one where the total throughput increases without the latency of a client
becoming painful. More slots cost VRAM: always check that the model stays 100 % GPU (`ollama ps`).

**Result on the reference machine (`concurrency`, 45 measurements, ≈ 8 min, KV cache `f16`, context 16,384, prompt
≈ 1,000 tokens, 128 tokens per client).**

| Simultaneous clients | First token (mean, `NUM_PARALLEL` 1 / 2 / 4) | Total throughput (tok/s) |
|---|---|---|
| 1 | 1.14 / 1.13 / 1.11 s | 36.1 / 38.1 / 36.4 |
| 2 | 2.86 / 2.90 / 2.87 s | 36.6 / 36.7 / 36.6 |
| 4 | 6.40 / 6.33 / 6.42 s | 36.2 / 36.9 / 36.4 |

- **Requests are handled one after the other, whatever `NUM_PARALLEL` is.** The total throughput stays at ≈ 36-38 tok/s
  (it does not grow with the clients), each client's speed stays at ≈ 54 tok/s when it is served, and the first token
  arrives later and later: with 4 clients, the total duration is ≈ 4 times that of one client (13.9 s versus 3.5 s).
- **`NUM_PARALLEL=2` or `4` had no measurable effect, neither on speed nor on memory** (VRAM 19,521 to 19,523 MiB in all
  three cases, whereas four slots should reserve four times more cache). **Cause confirmed by the server log**
  (`server-logs.txt`, with `NUM_PARALLEL` 4 and 2): Ollama writes
  `model architecture does not currently support parallel requests architecture=qwen35`, then starts the engine with
  `-np 1` (a single slot, `n_slots = 1`). The setting is therefore ignored for this model (`qwen35` architecture) in
  this version of Ollama. This could change with an Ollama update or another model: test again then.
- **Practical consequence:** do not raise `OLLAMA_NUM_PARALLEL` hoping to serve several requests faster: here, nothing is
  gained. With `NUM_PARALLEL=1` (current value), two simultaneous requests (n8n and Open WebUI for example) queue up: the
  second waits for the first to finish (≈ 3.5 s for a 128-token answer), without error.
- Measured in `f16`, with a single model loaded; the prefix cache (§3.5) was not tested with several clients.

## 4. Reading a report without getting it wrong

### 4.1 The files

| File | Content | Use it for |
|---|---|---|
| `summary.csv` | **Absolute** values per condition (tok/s, seconds, watts…), with confidence interval and CV | Knowing "how much" |
| `comparisons.csv` | Differences **in percent relative to the baseline** | Knowing "better or worse than the baseline" |
| `runs.csv` | One line per measurement | Looking for an outlier |
| `telemetry.csv` | GPU state at 10 samples per second | Understanding throttling or heat |
| `report.html` | All of that with charts and warnings | General reading |
| `meta.json` | Settings actually used, Ollama version | Checking under which conditions the measurement was made |

### 4.2 The four questions to ask of every number

1. **What is the margin of error?** A value without a confidence interval is just a number. If the intervals of two
   conditions overlap, the difference is not demonstrated.
2. **Is it significant?** The report marks a difference as "significant" only if the interval of the difference
   excludes 0.
3. **Is it larger than the noise?** The report gives the **smallest detectable difference**: below it, a difference is
   indistinguishable from chance. For the reference machine at the time of the `power-sweep`: ≈ 10.5 %.
4. **Is the baseline reliable?** A percentage only makes sense if the baseline is good (see §4.3).

### 4.3 A pitfall met for real (`context-scaling`)

`comparisons.csv` announced that generation was **+19 % to +22 % faster** with a large context than the baseline. That is
counter-intuitive: more text should not speed up generation. Reading `summary.csv`, the cause appears: the baseline point
(512 tokens) is abnormally slow (48.6 tok/s versus ≈ 58), with lower power and clock: very short trials, GPU not yet up
to speed. The percentages inherit that. **Moral: when a result is counter-intuitive, look at the absolute values before
concluding.**

### 4.3b A second pitfall met for real (`kv-cache`)

A decoding speed computed on **4 to 7 tokens** is not a speed: it changes with the number of tokens (from 61 to 109
tok/s in the same run) and its error margins are huge. Before reading `decode_tps`, open `runs.csv` and look at the
`gen_tokens` column: several dozen are needed at least. Needle-based experiments (the answer is a code) do not measure
decoding; the `mixed` workload (long text requested) does. Same reflex for joules per token: if `energy_j` covers a 19 s
prefill for 5 generated tokens, the result (> 1,000 J/token) makes no sense.

### 4.4 The report's automatic warnings

The report flags: too few repetitions; high noise (CV > 5 %), so the machine is not isolated; drift over time (speed
changes with the order of measurements); thermal or hardware throttling; model partly on the CPU. A warning does not
give the cause: it is up to you to look (a background application, the room temperature…).

### 4.5 The conditions of a good measurement

- **Isolated machine**: the bench stops the production Ollama; also stop ComfyUI and Hermes, and keep the remote desktop
  off (it draws ≈ 100 W and skews the comparison).
- **Explicit model**: always pass `--model qwen3.8:27b` (or your model). Otherwise, `lab bench` takes the first loaded
  model, which may be the small task model.
- **Same model, same Ollama version** as the ones you use: results do not carry over from another model.
- **Note the machine's state** (remote desktop, room temperature) to be able to compare later.

## 5. Glossary

| Term | Definition |
|---|---|
| **Token** | Piece of text (word, part of a word, punctuation): the unit the model reads and writes. About 3 to 4 characters in English. |
| **Prompt** | All the text sent to the model for a request: instructions, history, documents, question. |
| **Context / context window** | Maximum number of tokens the model considers at once (prompt + answer). |
| **Reservation vs fill** | `num_ctx` reserves the window; the fill is the text actually in it. Waiting time follows the fill, memory (in principle) follows the reservation. |
| **`num_ctx`** | Ollama setting for the size of that window for one request. `OLLAMA_CONTEXT_LENGTH` gives the default value. |
| **Prefill** | Phase where the model **reads** the prompt before answering. Measured in tokens read per second. |
| **Generation (decode)** | Phase where the model **writes** the answer, token after token. Measured in tokens/s. |
| **tok/s** | Tokens per second: the speed. |
| **TTFT** (*time to first token*) | Delay between sending the request and the first token of the answer: the waiting time you feel. Depends mostly on the prefill. |
| **ITL** (*inter-token latency*) | Delay between two successive tokens; its p95 value says that 95 % of the delays are below it. |
| **p50 / p95 / p99** | Percentiles: value below which 50 %, 95 %, 99 % of the measurements lie. The p95 describes the "bad days". |
| **KV cache** | Memory where the model keeps the intermediate results of all the text already seen, so as not to recompute them. |
| **Quantisation** | Compressed storage (fewer bits per value): less memory, possibly at the cost of precision. |
| **`f16` / `q8_0` / `q4_0`** | Precision of the KV cache: 16 bits (full), 8 bits, 4 bits. |
| **Flash attention** | A way of computing attention that is faster and uses less memory; required to quantise the KV cache. |
| **VRAM** | The card's video memory (24 GB on the 3090) where the model and the KV cache live. |
| **100 % GPU** | The whole model is in VRAM. Less than that = part of it on the CPU, much slower. |
| **Power limit** | Cap in watts imposed on the GPU. |
| **SM clock** | Clock speed of the GPU's compute units (in MHz); it drops when the card is capped. |
| **Throttling** | Automatic clock reduction, due to the power limit, the temperature, or a hardware protection. |
| **J/token** | Energy per generated token (joules). In these measurements it **includes the prefill**: a long prompt makes it explode without generation becoming less efficient. |
| **`P8` state** | GPU idle mode (≈ 20 W). A GPU that does not return to it indicates a background load. |
| **Repetition** | A measurement redone under the same conditions, to estimate the noise. |
| **Warm-up** | Uncounted measurement made beforehand, so that the model and the card are ready. |
| **Cool-down** | Waiting for the GPU to come back down to a target temperature between two measurements. |
| **Baseline** | Condition the others are compared with. |
| **Factor** | Setting that varies from one condition to another in an experiment. |
| **Factorial design** | All combinations of the factors' values. |
| **95 % confidence interval (CI)** | Range in which the true value lies with 95 % probability, according to the sample. |
| **CV** (coefficient of variation) | Relative spread of the measurements (standard deviation ÷ mean). The larger it is, the noisier. |
| **Significant** | A difference whose CI excludes 0: unlikely to be due to chance. |
| **Smallest detectable difference** | Minimum size of difference that this number of repetitions can tell apart from noise. |
| **Wilson interval** | Confidence interval suited to proportions (success rates). |
| **Needle** | Retrieval test: a piece of information hidden in a long text, which the model must find. |
| **Prefix cache** | Reuse of the work done on an identical prompt start between two requests. |
| **`OLLAMA_NUM_PARALLEL`** | Number of requests handled simultaneously by the same model. |
| **`OLLAMA_KEEP_ALIVE`** | How long a model stays in VRAM after its last use (30 min here). |
| **`OLLAMA_MAX_LOADED_MODELS`** | Number of models loaded at the same time (2 with the task model). |
| **Perplexity** | Rigorous measure of a model's quality on a text; not done here. |

## 6. What is not verified

- The definitions in §5 and the explanations in §3 are general explanations; they do not come from measurements. Only
  the "Result on the reference machine" paragraphs do.
- The "about half" and "about a quarter" figures for the quantised cache are properties of the format, not measurements.
  The VRAM saved was read in the `runs.csv` of `kv-cache` (see §3.3).
- The choice criteria in §3.3 (keep `q8_0` if it is not slower and finds the needle as well) are a reading proposal, not
  an established rule.
- `prefix-cache` and `concurrency` were measured with an `f16` cache only; `NUM_PARALLEL` is ignored by Ollama for the
  `qwen35` architecture (confirmed by the log).
- `ctx-window`: only 4 repetitions per condition; the combination "98,304 + small task model" and the value of `num_ctx`
  actually applied at 98,304 (`ctx_effective` column of `runs.csv`) were not checked.
- The `peak_mem_used_mb` column in the report tables (`bench/labbench/report.py`) was only tested with the fake-GPU test
  suite, not on a real report. When in doubt, the column is in `runs.csv`.
- The `power-sweep` and `power-confirm` results were obtained with the remote desktop in a state not noted for the
  second; their comparison with `context-scaling` (generation at 58 tok/s versus 50 measured in the `power-sweep`)
  remains unexplained.
