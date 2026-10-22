"""Accès au GPU : mesures (NVML) et réglage de la limite de puissance.

Mode simulé (LABBENCH_FAKE_GPU=1) uniquement pour les tests automatiques sans carte graphique.
"""
from __future__ import annotations

import math
import os
import subprocess
import threading
import time
from dataclasses import dataclass

# Bits de "clocks throttle reasons" (valeurs fixées par NVML)
THR_IDLE = 0x1
THR_SW_POWER_CAP = 0x4
THR_HW_SLOWDOWN = 0x8
THR_SW_THERMAL = 0x20
THR_HW_THERMAL = 0x40
THR_HW_POWER_BRAKE = 0x80


@dataclass
class GpuInfo:
    name: str
    driver: str
    power_default_w: float
    power_min_w: float
    power_max_w: float
    power_limit_w: float
    mem_total_mb: float


class RealGpu:
    def __init__(self, index: int = 0):
        import pynvml  # nvidia-ml-py

        self.nv = pynvml
        self.nv.nvmlInit()
        self.index = index
        self.h = self.nv.nvmlDeviceGetHandleByIndex(index)
        self._has_energy = True

    @staticmethod
    def _s(x):
        return x.decode() if isinstance(x, bytes) else x

    def info(self) -> GpuInfo:
        nv = self.nv
        lo, hi = nv.nvmlDeviceGetPowerManagementLimitConstraints(self.h)
        return GpuInfo(
            name=self._s(nv.nvmlDeviceGetName(self.h)),
            driver=self._s(nv.nvmlSystemGetDriverVersion()),
            power_default_w=nv.nvmlDeviceGetPowerManagementDefaultLimit(self.h) / 1000.0,
            power_min_w=lo / 1000.0,
            power_max_w=hi / 1000.0,
            power_limit_w=nv.nvmlDeviceGetPowerManagementLimit(self.h) / 1000.0,
            mem_total_mb=nv.nvmlDeviceGetMemoryInfo(self.h).total / 2**20,
        )

    def energy_mj(self) -> float:
        """Compteur d'énergie cumulée (mJ) depuis le chargement du pilote : mesure exacte, pas une intégrale d'échantillons."""
        try:
            return float(self.nv.nvmlDeviceGetTotalEnergyConsumption(self.h))
        except Exception:
            self._has_energy = False
            return math.nan

    def _throttle(self) -> int:
        nv = self.nv
        for name in ("nvmlDeviceGetCurrentClocksEventReasons", "nvmlDeviceGetCurrentClocksThrottleReasons"):
            fn = getattr(nv, name, None)
            if fn:
                try:
                    return int(fn(self.h))
                except Exception:
                    pass
        return 0

    def sample(self) -> dict:
        nv = self.nv
        util = nv.nvmlDeviceGetUtilizationRates(self.h)
        return {
            "t": time.time(),
            "power_w": nv.nvmlDeviceGetPowerUsage(self.h) / 1000.0,
            "energy_mj": self.energy_mj(),
            "temp_c": float(nv.nvmlDeviceGetTemperature(self.h, nv.NVML_TEMPERATURE_GPU)),
            "sm_mhz": float(nv.nvmlDeviceGetClockInfo(self.h, nv.NVML_CLOCK_SM)),
            "mem_mhz": float(nv.nvmlDeviceGetClockInfo(self.h, nv.NVML_CLOCK_MEM)),
            "util_gpu": float(util.gpu),
            "util_mem": float(util.memory),
            "mem_used_mb": nv.nvmlDeviceGetMemoryInfo(self.h).used / 2**20,
            "throttle": self._throttle(),
        }

    def power_limit_w(self) -> float:
        return self.nv.nvmlDeviceGetPowerManagementLimit(self.h) / 1000.0

    def set_power_limit(self, watts: float, settle_s: float = 3.0) -> None:
        """Nécessite les droits root : 'sudo -n nvidia-smi -pl'. Le script 7-bench.sh prépare 'sudo -v'."""
        info = self.info()
        if not (info.power_min_w - 0.5 <= watts <= info.power_max_w + 0.5):
            raise ValueError(f"{watts} W hors bornes du GPU [{info.power_min_w}, {info.power_max_w}] W")
        r = subprocess.run(["sudo", "-n", "nvidia-smi", "-i", str(self.index), "-pl", str(int(round(watts)))],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(
                "Impossible de régler la limite de puissance (droits sudo ?).\n"
                f"stderr: {r.stderr.strip()}\nLance d'abord 'sudo -v' dans ce terminal, puis relance.")
        time.sleep(settle_s)
        got = self.power_limit_w()
        if abs(got - round(watts)) > 1.5:
            raise RuntimeError(f"Limite demandée {watts} W mais le GPU rapporte {got} W.")


class FakeGpu:
    """GPU simulé pour tester la chaîne complète sans matériel. Pas utilisé en production."""

    def __init__(self, index: int = 0):
        self.index = index
        self.limit = 350.0
        self.activity = 0.0       # 0..1, piloté par le faux serveur Ollama
        self._e = 0.0
        self._t = time.time()
        self._temp = 40.0
        self._lock = threading.Lock()
        self.mem_used = 1200.0

    def _advance(self):
        now = time.time()
        dt = now - self._t
        self._t = now
        p = self._power()
        self._e += p * dt * 1000.0
        target = 38 + (p - 25) * 0.16
        self._temp += (target - self._temp) * min(1.0, dt / 20.0)

    def _power(self) -> float:
        draw = 25 + self.activity * (330 - 25)
        return min(draw, self.limit)

    def info(self) -> GpuInfo:
        return GpuInfo("FakeGPU RTX 3090", "000.00", 350.0, 100.0, 390.0, self.limit, 24576.0)

    def energy_mj(self) -> float:
        with self._lock:
            self._advance()
            return self._e

    def sample(self) -> dict:
        with self._lock:
            self._advance()
            p = self._power()
            capped = self.activity > 0.5 and p >= self.limit - 1
            return {"t": time.time(), "power_w": p, "energy_mj": self._e, "temp_c": self._temp,
                    "sm_mhz": 1900 - (350 - self.limit) * 2.2 if self.activity > 0 else 210.0,
                    "mem_mhz": 9501.0, "util_gpu": 100.0 * self.activity, "util_mem": 60.0 * self.activity,
                    "mem_used_mb": self.mem_used, "throttle": THR_SW_POWER_CAP if capped else THR_IDLE}

    def power_limit_w(self) -> float:
        return self.limit

    def set_power_limit(self, watts: float, settle_s: float = 0.0) -> None:
        self.limit = float(watts)


def open_gpu(index: int = 0):
    if os.environ.get("LABBENCH_FAKE_GPU") == "1":
        return FakeGpu(index)
    return RealGpu(index)
