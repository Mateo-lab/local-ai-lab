"""Reading an experiment (YAML) and building the experimental design (factorial grid)."""
from __future__ import annotations

import hashlib
import itertools
import json
import random
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

# Factors that require restarting the Ollama server (environment variables)
SERVER_FACTORS = ("kv_cache_type", "flash_attention", "num_parallel")
KNOWN_FACTORS = {
    "power_limit_w", "kv_cache_type", "flash_attention", "num_parallel",
    "num_ctx", "ctx_depth", "gen_tokens", "clients", "needle_depth", "think",
}

DEFAULTS: dict[str, Any] = {
    "name": "experiment",
    "model": None,
    "image": "ollama/ollama:latest",
    "seed": 1234,
    "repetitions": 5,
    "warmup": 1,
    "design": "randomized",         # randomized (all shuffled) | blocked (conditions grouped)
    "cooldown": {"target_c": 60, "max_wait_s": 600},
    "idle_s": 20,                    # idle power measurement before the experiment
    "server": {"kv_cache_type": "f16", "flash_attention": 1, "num_parallel": 1, "keep_alive": "30m"},
    "request": {"num_ctx": 8192, "ctx_depth": 512, "gen_tokens": 256, "clients": 1, "think": False,
                "temperature": 0.0, "needle_depth": 0.5},
    "workload": "mixed",             # mixed | needle | prefix_cache | concurrency | arith | arith_easy
    "factors": {},
    "baseline": {},                  # baseline levels for the comparisons (otherwise: 1st value of each factor)
    "report": {"x": None},
}


@dataclass
class Condition:
    cid: str
    values: dict[str, Any]                 # value of each factor (including those fixed by default)
    factor_values: dict[str, Any]          # only the varying factors
    server_key: tuple = field(default_factory=tuple)


@dataclass
class Experiment:
    raw: dict[str, Any]
    conditions: list[Condition]

    @property
    def name(self) -> str:
        return self.raw["name"]


def _deep_merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def load_experiment(path: str | Path, model: str | None = None) -> Experiment:
    raw = _deep_merge(DEFAULTS, yaml.safe_load(Path(path).read_text()) or {})
    if model:
        raw["model"] = model
    if not raw.get("model"):
        raise ValueError("No model: set 'model:' in the YAML or pass --model NAME.")
    unknown = set(raw["factors"]) - KNOWN_FACTORS
    if unknown:
        raise ValueError(f"Unknown factors: {sorted(unknown)} (known: {sorted(KNOWN_FACTORS)})")
    for k, v in raw["factors"].items():
        if not isinstance(v, list) or not v:
            raise ValueError(f"Factor '{k}' must be a non-empty list.")
    base_vals = {**raw["server"], **raw["request"]}
    names = list(raw["factors"])
    conds: list[Condition] = []
    for combo in itertools.product(*[raw["factors"][n] for n in names]):
        fv = dict(zip(names, combo))
        vals = {**base_vals, **fv}
        cid = hashlib.sha1(json.dumps(fv, sort_keys=True, default=str).encode()).hexdigest()[:8]
        skey = tuple(vals.get(k) for k in SERVER_FACTORS) + (vals.get("keep_alive"),)
        conds.append(Condition(cid=cid, values=vals, factor_values=fv, server_key=skey))
    if not conds:  # no variable: a single condition (baseline / noise measurement)
        vals = dict(base_vals)
        conds.append(Condition(cid="base0000", values=vals, factor_values={},
                               server_key=tuple(vals.get(k) for k in SERVER_FACTORS) + (vals.get("keep_alive"),)))
    return Experiment(raw=raw, conditions=conds)


def plan_runs(exp: Experiment) -> list[tuple[Condition, int]]:
    """Run order: (condition, repetition). Server factors stay grouped (blocks)
    because each block requires restarting Ollama; inside a block, the order is random
    (completely randomised design) to avoid mistaking a factor for a thermal drift."""
    rng = random.Random(exp.raw["seed"])
    reps = int(exp.raw["repetitions"])
    blocks: dict[tuple, list[tuple[Condition, int]]] = {}
    for c in exp.conditions:
        for r in range(reps):
            blocks.setdefault(c.server_key, []).append((c, r))
    ordered: list[tuple[Condition, int]] = []
    keys = list(blocks)
    rng.shuffle(keys)
    for k in keys:
        items = blocks[k]
        if exp.raw["design"] == "randomized":
            rng.shuffle(items)
        ordered.extend(items)
    return ordered
