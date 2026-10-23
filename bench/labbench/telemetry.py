"""Background GPU telemetry sampler (10 Hz by default) + per-window summaries."""
from __future__ import annotations

import csv
import math
import threading
import time
from pathlib import Path

import numpy as np

from . import gpu as g


class Sampler:
    def __init__(self, gpu, interval_s: float = 0.1):
        self.gpu = gpu
        self.interval = interval_s
        self.rows: list[dict] = []
        self.current_run: str = ""
        self._stop = threading.Event()
        self._th = threading.Thread(target=self._loop, daemon=True)
        self._lock = threading.Lock()

    def start(self):
        self._th.start()
        return self

    def stop(self):
        self._stop.set()
        self._th.join(timeout=2)

    def _loop(self):
        nxt = time.time()
        while not self._stop.is_set():
            try:
                s = self.gpu.sample()
                s["run"] = self.current_run
                with self._lock:
                    self.rows.append(s)
            except Exception:
                pass
            nxt += self.interval
            time.sleep(max(0.0, nxt - time.time()))

    def window(self, t0: float, t1: float) -> list[dict]:
        with self._lock:
            return [r for r in self.rows if t0 <= r["t"] <= t1]

    def latest_temp(self) -> float:
        with self._lock:
            return self.rows[-1]["temp_c"] if self.rows else math.nan

    def summarize(self, t0: float, t1: float, energy_start_mj: float, energy_end_mj: float) -> dict:
        w = self.window(t0, t1)
        out = {"energy_j": (energy_end_mj - energy_start_mj) / 1000.0 if not math.isnan(energy_start_mj) else math.nan,
               "n_samples": len(w)}
        if not w:
            return out | {k: math.nan for k in ("avg_power_w", "max_power_w", "max_temp_c", "avg_sm_mhz",
                                                 "avg_mem_mhz", "avg_util_gpu", "peak_mem_used_mb",
                                                 "thr_power_frac", "thr_thermal_frac", "thr_hw_frac")}
        a = lambda k: np.array([r[k] for r in w], float)
        thr = np.array([r["throttle"] for r in w], int)
        busy = a("util_gpu") > 5
        busy_n = max(1, int(busy.sum()))
        return out | {
            "avg_power_w": float(a("power_w").mean()),
            "max_power_w": float(a("power_w").max()),
            "max_temp_c": float(a("temp_c").max()),
            "avg_sm_mhz": float(a("sm_mhz")[busy].mean()) if busy.any() else float(a("sm_mhz").mean()),
            "avg_mem_mhz": float(a("mem_mhz").mean()),
            "avg_util_gpu": float(a("util_gpu").mean()),
            "peak_mem_used_mb": float(a("mem_used_mb").max()),
            # shares of time (among "GPU busy" samples) where a throttling reason is active
            "thr_power_frac": float(((thr & g.THR_SW_POWER_CAP) > 0)[busy].sum() / busy_n) if busy.any() else 0.0,
            "thr_thermal_frac": float((((thr & (g.THR_SW_THERMAL | g.THR_HW_THERMAL)) > 0))[busy].sum() / busy_n) if busy.any() else 0.0,
            "thr_hw_frac": float((((thr & (g.THR_HW_SLOWDOWN | g.THR_HW_POWER_BRAKE)) > 0))[busy].sum() / busy_n) if busy.any() else 0.0,
        }

    def dump_csv(self, path: Path):
        with self._lock:
            rows = list(self.rows)
        if not rows:
            return
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
