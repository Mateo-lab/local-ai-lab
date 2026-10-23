"""Workloads. Every prompt starts with a unique nonce: without it, Ollama reuses the prefix (KV) cache
of a previous run and the prefill measurement would be skewed (except for 'prefix_cache', where that is
precisely what is measured).
The prompts were in French in the first versions: results from those runs are not strictly comparable."""
from __future__ import annotations

import math
import random
import re
import threading
import time
import uuid

import numpy as np

from .ollama import GenResult, OllamaClient

_WORDS = ("frame signal window engine river table light chapter horizon speed matrix curve "
          "memory network sensor battery voltage frequency layer model input output segment buffer "
          "latency throughput token vector kernel register channel phase threshold measure error balance").split()


def filler(n_tokens: int, rng: random.Random, chars_per_token: float) -> str:
    """Reproducible pseudo-random text of about n_tokens tokens."""
    target = int(max(0, n_tokens) * chars_per_token)
    out, size = [], 0
    while size < target:
        s = " ".join(rng.choice(_WORDS) for _ in range(rng.randint(6, 14))).capitalize() + ". "
        out.append(s)
        size += len(s)
    return "".join(out)[:target]


def calibrate(client: OllamaClient, model: str, num_ctx: int) -> float:
    """Estimates characters/token for this model with a short request (num_predict=1)."""
    rng = random.Random(7)
    text = filler(400, rng, 4.0)
    r = client.generate(model, f"[{uuid.uuid4().hex}] {text}\nOK ?", num_ctx=max(num_ctx, 2048), num_predict=1)
    if not r.ok or r.prompt_tokens <= 20:
        return 3.2
    return max(1.5, min(8.0, (len(text) + 40) / r.prompt_tokens))


def _nonce() -> str:
    return f"[run {uuid.uuid4().hex}]"


def _pct(x: list[float], q: float) -> float:
    return float(np.percentile(x, q)) if x else math.nan


def _common(results: list[GenResult]) -> dict:
    ok = [r for r in results if r.ok]
    itl = [v for r in ok for v in r.itl_ms]
    return {
        "n_ok": len(ok), "n_err": len(results) - len(ok),
        "error": next((r.error for r in results if not r.ok), ""),
        "prompt_tokens": sum(r.prompt_tokens for r in ok),
        "gen_tokens": sum(r.gen_tokens for r in ok),
        "ttft_s": float(np.mean([r.ttft_s for r in ok])) if ok else math.nan,
        "prefill_tps": float(np.nanmean([r.prefill_tps for r in ok])) if ok else math.nan,
        "decode_tps": float(np.nanmean([r.decode_tps for r in ok])) if ok else math.nan,
        "itl_p50_ms": _pct(itl, 50), "itl_p95_ms": _pct(itl, 95), "itl_p99_ms": _pct(itl, 99),
        "load_s": float(np.mean([r.load_s for r in ok])) if ok else math.nan,
    }


def _gen_kwargs(v: dict, num_predict: int | None = None) -> dict:
    return dict(num_ctx=int(v["num_ctx"]), num_predict=int(num_predict or v["gen_tokens"]),
                think=bool(v.get("think", False)), temperature=float(v.get("temperature", 0.0)),
                keep_alive=str(v.get("keep_alive", "30m")))


def check_fits(v: dict) -> str | None:
    need = int(v["ctx_depth"]) + int(v["gen_tokens"]) + 64
    if need > int(v["num_ctx"]):
        return f"ctx_depth({v['ctx_depth']}) + gen_tokens({v['gen_tokens']}) exceeds num_ctx({v['num_ctx']})"
    return None


def run_mixed(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    rng = random.Random(seed)
    prompt = (f"{_nonce()}\nHere is some filler text:\n{filler(int(v['ctx_depth']), rng, cpt)}\n\n"
              "Now write a long, detailed descriptive text about how a graphics processor works.")
    r = c.generate(model, prompt, seed=seed, **_gen_kwargs(v))
    return _common([r])


def run_needle(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    rng = random.Random(seed)
    code = "".join(rng.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(6))
    depth = float(v.get("needle_depth", 0.5))
    total = int(v["ctx_depth"])
    before = filler(int(total * depth), rng, cpt)
    after = filler(int(total * (1 - depth)), rng, cpt)
    prompt = (f"{_nonce()}\nRead the following text.\n\n{before}\nIMPORTANT INFORMATION: the secret code is {code}.\n"
              f"{after}\n\nQuestion: what is the secret code? Answer with the code only.")
    # if "think" is on, room must be left for the reasoning
    r = c.generate(model, prompt, seed=seed, **_gen_kwargs(v, num_predict=int(v["gen_tokens"])))
    out = _common([r])
    found = code in (r.text or "").upper().replace(" ", "") if r.ok else False
    out["quality"] = 1.0 if found else 0.0
    return out


def run_prefix_cache(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    rng = random.Random(seed)
    prefix = f"{_nonce()}\n{filler(int(v['ctx_depth']), rng, cpt)}\n\n"
    kw = _gen_kwargs(v, num_predict=min(32, int(v["gen_tokens"])))
    cold = c.generate(model, prefix + "Summarise in one sentence.", seed=seed, **kw)
    warm = c.generate(model, prefix + "Summarise in two words.", seed=seed, **kw)
    out = _common([cold])
    out.update({
        "cold_prompt_eval_s": cold.prompt_eval_s, "warm_prompt_eval_s": warm.prompt_eval_s,
        "cold_prompt_tokens": cold.prompt_tokens, "warm_prompt_tokens": warm.prompt_tokens,
        "cold_ttft_s": cold.ttft_s, "warm_ttft_s": warm.ttft_s,
        "cache_ttft_speedup": (cold.ttft_s / warm.ttft_s) if warm.ok and warm.ttft_s and warm.ttft_s > 0 else math.nan,
        # share of the reading work avoided = 1 - prompt reading time (2nd request) / reading time (1st request).
        # Measured: Ollama reports prompt_eval_count with the COMPLETE prompt even when the prefix is reused,
        # so a calculation on token counts always gave 0; the time, on the other hand, drops from 18 s to 0.7 s.
        "cache_reuse_frac": (1 - warm.prompt_eval_s / cold.prompt_eval_s) if (cold.prompt_eval_s and cold.prompt_eval_s > 0 and warm.ok) else math.nan,
    })
    return out


def run_concurrency(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    n = int(v.get("clients", 1))
    results: list[GenResult | None] = [None] * n

    def one(i):
        rng = random.Random(seed * 1000 + i)
        prompt = (f"{_nonce()}\n{filler(int(v['ctx_depth']), rng, cpt)}\n\n"
                  "Write a long descriptive text about memory management in a computer.")
        results[i] = c.generate(model, prompt, seed=seed + i, **_gen_kwargs(v))

    t0 = time.perf_counter()
    th = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    [t.start() for t in th]
    [t.join() for t in th]
    wall = time.perf_counter() - t0
    rs = [r for r in results if r is not None]
    out = _common(rs)
    out["wall_s"] = wall
    out["agg_tps"] = out["gen_tokens"] / wall if wall > 0 else math.nan
    out["clients"] = n
    return out


def run_arith(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    """Small quality test: 12 calculations. Sensitive to degradation due to aggressive KV cache quantisation."""
    rng = random.Random(4242)  # same questions at every run: only the configuration varies
    qs = []
    for _ in range(12):
        a, b, cc = rng.randint(120, 989), rng.randint(12, 97), rng.randint(100, 900)
        qs.append((f"Compute {a} * {b} + {cc}. Answer with the number only.", a * b + cc))
    ok, rs = 0, []
    for q, ans in qs:
        r = c.generate(model, f"{_nonce()}\n{q}", seed=seed, **_gen_kwargs(v, num_predict=int(v["gen_tokens"])))
        rs.append(r)
        nums = re.findall(r"-?\d[\d\s,.]*", (r.text or ""))
        got = [re.sub(r"[\s,.]", "", s) for s in nums]
        ok += int(r.ok and str(ans) in got)
    out = _common(rs)
    out["quality"] = ok / len(qs)
    out["quality_n"] = len(qs)
    return out


ARITH_EASY_N = 150


def run_arith_easy(c: OllamaClient, model: str, v: dict, seed: int, cpt: float) -> dict:
    """Finer quality test than `arith`: 150 EASY calculations (2 digits × 1 digit + 2 digits), same questions
    for every cache type. The model must get the vast majority right without reasoning, so that a loss is visible.
    The temperature is zero, but a random identifier is placed at the start of each prompt: two repetitions may differ
    by a question or two (observed). The contexts are short (≈ 65 tokens per question): the KV cache gets little load."""
    rng = random.Random(777)
    qs = []
    for _ in range(ARITH_EASY_N):
        a, b, cc = rng.randint(12, 99), rng.randint(2, 9), rng.randint(10, 99)
        qs.append((f"Compute {a} * {b} + {cc}. Answer with the number only.", a * b + cc))
    ok, rs = 0, []
    for q, ans in qs:
        r = c.generate(model, f"{_nonce()}\n{q}", seed=seed, **_gen_kwargs(v, num_predict=int(v["gen_tokens"])))
        rs.append(r)
        nums = re.findall(r"-?\d[\d\s,.]*", (r.text or ""))
        got = [re.sub(r"[\s,.]", "", s) for s in nums]
        ok += int(r.ok and str(ans) in got)
    out = _common(rs)
    out["quality"] = ok / len(qs)
    out["quality_n"] = len(qs)
    return out


WORKLOADS = {"mixed": run_mixed, "needle": run_needle, "prefix_cache": run_prefix_cache,
             "concurrency": run_concurrency, "arith": run_arith, "arith_easy": run_arith_easy}
