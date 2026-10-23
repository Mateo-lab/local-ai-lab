"""Running an experiment: randomised plan, warm-up, cool-down, telemetry, resume after interruption."""
from __future__ import annotations

import csv
import datetime as dt
import json
import math
import platform
import time
from pathlib import Path

from . import __version__
from .config import KNOWN_FACTORS, Condition, Experiment, plan_runs
from .ollama import ManagedServer, OllamaClient, server_env
from .telemetry import Sampler
from .workloads import WORKLOADS, calibrate, check_fits

FACTOR_COLS = sorted(KNOWN_FACTORS)


def _log(msg: str) -> None:
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def _read_done(path: Path) -> set[str]:
    if not path.exists():
        return set()
    with open(path, newline="") as f:
        return {r["run_id"] for r in csv.DictReader(f) if r.get("run_id")}


def _append(path: Path, row: dict) -> None:
    new = not path.exists()
    if not new:  # keep the columns consistent: read the existing header back
        with open(path, newline="") as f:
            header = next(csv.reader(f))
    else:
        header = list(row.keys())
    with open(path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=header, extrasaction="ignore")
        if new:
            w.writeheader()
        w.writerow(row)


def wait_cooldown(sampler: Sampler, target_c: float, max_wait_s: float) -> float:
    t0 = time.time()
    while time.time() - t0 < max_wait_s:
        if sampler.latest_temp() <= target_c:
            break
        time.sleep(1.0)
    return time.time() - t0


def measure_idle(gpu, seconds: float) -> dict:
    s = Sampler(gpu, 0.2).start()
    t0 = time.time(); e0 = gpu.energy_mj()
    time.sleep(seconds)
    e1 = gpu.energy_mj(); t1 = time.time()
    s.stop()
    return s.summarize(t0, t1, e0, e1)


def run_experiment(exp: Experiment, gpu, outdir: Path, *, mode: str = "managed", external_url: str | None = None,
                   volume: str = "ai-stack_ollama_data", port: int = 11435, dry_run: bool = False,
                   log=_log) -> Path:
    raw = exp.raw
    outdir.mkdir(parents=True, exist_ok=True)
    runs_csv, tele_csv = outdir / "runs.csv", outdir / "telemetry.csv"
    plan = plan_runs(exp)
    wl = WORKLOADS[raw["workload"]]
    info = gpu.info()
    original_limit = gpu.power_limit_w()

    (outdir / "experiment.json").write_text(json.dumps(raw, indent=2, default=str))
    (outdir / "plan.json").write_text(json.dumps(
        [{"seq": i, "cid": c.cid, "rep": r, "factors": c.factor_values} for i, (c, r) in enumerate(plan)], indent=2, default=str))
    done = _read_done(runs_csv)
    todo = [(i, c, r) for i, (c, r) in enumerate(plan) if f"{c.cid}_{r}" not in done]
    log(f"Plan: {len(plan)} measurements ({len(exp.conditions)} conditions × {raw['repetitions']} repetitions), "
        f"{len(done)} already done, {len(todo)} remaining.")
    for c in exp.conditions:
        problem = check_fits(c.values) if raw["workload"] not in ("arith", "arith_easy") else None
        if problem:
            raise ValueError(f"Condition {c.factor_values}: {problem}")
    if dry_run:
        for i, c, r in todo[:30]:
            log(f"  #{i:03d} {c.cid} rep{r} {c.factor_values}")
        return outdir

    if mode == "external":
        varied = [k for k in raw["factors"] if k in ("kv_cache_type", "flash_attention", "num_parallel")]
        if varied:
            raise ValueError(f"External mode: cannot vary {varied} (server restart required).")

    meta = {"labbench": __version__, "started": dt.datetime.now().isoformat(timespec="seconds"),
            "host": platform.node(), "gpu": info.__dict__, "mode": mode, "original_power_limit_w": original_limit}
    sampler = Sampler(gpu, 0.1).start()
    idle_s = float(raw.get("idle_s", 0))
    if idle_s > 0 and not done:
        log(f"Idle power ({idle_s:.0f} s)…")
        meta["idle"] = measure_idle(gpu, idle_s)
        log(f"  repos : {meta['idle'].get('avg_power_w', math.nan):.1f} W, {meta['idle'].get('max_temp_c', math.nan):.0f} °C")
    elif (outdir / "meta.json").exists():
        meta["idle"] = json.loads((outdir / "meta.json").read_text()).get("idle", {})

    server = ManagedServer(raw["image"], volume, port) if mode == "managed" else None
    client: OllamaClient | None = OllamaClient(external_url) if mode == "external" else None
    current_skey, last_ctx, cpt, consecutive_fail = None, None, 3.2, 0
    model = raw["model"]
    try:
        if server:
            server.prepare()
        for n, (seq, cond, rep) in enumerate(todo, 1):
            v = cond.values
            if server and cond.server_key != current_skey:
                log(f"Nouveau bloc serveur : {dict(zip(('kv_cache_type', 'flash_attention', 'num_parallel'), cond.server_key))}")
                client = server.start(server_env(v))
                meta["ollama_version"] = client.version()
                current_skey, last_ctx = cond.server_key, None
                client.generate(model, "ok", num_ctx=int(v["num_ctx"]), num_predict=1)   # loading the model
                try:    # record of what Ollama really applied (parallelism, layers on GPU…)
                    with open(outdir / "server-logs.txt", "a", encoding="utf-8") as f:
                        f.write(f"=== bloc serveur {dict(zip(('kv_cache_type', 'flash_attention', 'num_parallel'), cond.server_key))} ===\n"
                                f"{server.log_excerpt()}\n\n")
                except Exception as e:      # jamais bloquant
                    log(f"  (server log not recorded: {e})")
                cpt = calibrate(client, model, int(v["num_ctx"]))
                meta.setdefault("chars_per_token", cpt)
                for w in range(int(raw["warmup"])):
                    log(f"  warm-up {w + 1}/{raw['warmup']}")
                    WORKLOADS[raw["workload"]](client, model, v, 999 + w, cpt)
            elif client and current_skey is None:       # external mode: first time
                current_skey = cond.server_key
                meta["ollama_version"] = client.version()
                client.generate(model, "ok", num_ctx=int(v["num_ctx"]), num_predict=1)
                cpt = calibrate(client, model, int(v["num_ctx"]))
                meta.setdefault("chars_per_token", cpt)
                for w in range(int(raw["warmup"])):
                    log(f"  warm-up {w + 1}/{raw['warmup']}")
                    WORKLOADS[raw["workload"]](client, model, v, 999 + w, cpt)
            assert client is not None

            if "power_limit_w" in v and v["power_limit_w"] is not None and abs(gpu.power_limit_w() - float(v["power_limit_w"])) > 0.5:
                gpu.set_power_limit(float(v["power_limit_w"]))
                log(f"  limite de puissance → {v['power_limit_w']} W")
            # reload the model if the context changes (otherwise Ollama does it during the measurement)
            if last_ctx != int(v["num_ctx"]):
                client.generate(model, "ok", num_ctx=int(v["num_ctx"]), num_predict=1)
                last_ctx = int(v["num_ctx"])

            waited = wait_cooldown(sampler, float(raw["cooldown"]["target_c"]), float(raw["cooldown"]["max_wait_s"]))
            run_id = f"{cond.cid}_{rep}"
            sampler.current_run = run_id
            temp0 = sampler.latest_temp()
            e0, t0 = gpu.energy_mj(), time.time()
            try:
                m = wl(client, model, v, int(raw["seed"]) * 1000 + seq, cpt)
            except Exception as e:  # a failed measurement must not kill the whole experiment
                m = {"n_ok": 0, "n_err": 1, "error": f"{type(e).__name__}: {e}"}
            e1, t1 = gpu.energy_mj(), time.time()
            sampler.current_run = ""
            tel = sampler.summarize(t0, t1, e0, e1)
            place = client.placement(model)
            gen = m.get("gen_tokens", 0) or 0
            row = {"run_id": run_id, "seq": seq, "cid": cond.cid, "rep": rep,
                   "t_start": t0, "wall_s": t1 - t0, "cooldown_wait_s": waited, "temp_start_c": temp0,
                   **{k: v.get(k) for k in FACTOR_COLS},
                   **m, **tel,
                   "gpu_frac": place["gpu_frac"], "ctx_effective": place["ctx"],
                   "j_per_token": (tel["energy_j"] / gen) if gen and not math.isnan(tel["energy_j"]) else math.nan,
                   "tokens_per_j": (gen / tel["energy_j"]) if gen and tel["energy_j"] and not math.isnan(tel["energy_j"]) else math.nan,
                   "power_limit_actual_w": gpu.power_limit_w()}
            _append(runs_csv, row)
            if m.get("n_err", 0) and not m.get("n_ok", 0):
                consecutive_fail += 1
                log(f"  [{n}/{len(todo)}] FAILED {run_id}: {m.get('error', '')[:150]}")
                if consecutive_fail >= 3:
                    raise RuntimeError("3 consecutive failures: stopping (run the same command again to resume).")
            else:
                consecutive_fail = 0
                log(f"  [{n}/{len(todo)}] {run_id} {cond.factor_values} → decode {m.get('decode_tps', math.nan):.1f} tok/s, "
                    f"prefill {m.get('prefill_tps', math.nan):.0f} tok/s, {tel.get('avg_power_w', math.nan):.0f} W, "
                    f"{tel.get('max_temp_c', math.nan):.0f} °C")
            (outdir / "meta.json").write_text(json.dumps(meta, indent=2, default=str))
    finally:
        sampler.stop()
        sampler.dump_csv(tele_csv)
        try:
            if abs(gpu.power_limit_w() - original_limit) > 0.5:
                gpu.set_power_limit(original_limit)
                log(f"Power limit restored: {original_limit:.0f} W")
        except Exception as e:
            log(f"!! Could not restore the power limit ({original_limit:.0f} W): {e}")
        if server:
            server.restore()
        meta["finished"] = dt.datetime.now().isoformat(timespec="seconds")
        (outdir / "meta.json").write_text(json.dumps(meta, indent=2, default=str))
    return outdir
