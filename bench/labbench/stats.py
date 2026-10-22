"""Statistiques utilisées par le banc d'essai (intervalles de confiance, bootstrap, Wilson)."""
from __future__ import annotations

import math
from typing import Sequence

import numpy as np
from scipy import stats as sps


def mean_ci(x: Sequence[float], conf: float = 0.95) -> tuple[float, float, float, float]:
    """Retourne (moyenne, écart-type, demi-largeur de l'IC, n) — IC de Student."""
    a = np.asarray([v for v in x if v is not None and not (isinstance(v, float) and math.isnan(v))], float)
    n = len(a)
    if n == 0:
        return (math.nan, math.nan, math.nan, 0)
    m = float(a.mean())
    if n == 1:
        return (m, math.nan, math.nan, 1)
    sd = float(a.std(ddof=1))
    half = float(sps.t.ppf(0.5 + conf / 2, n - 1) * sd / math.sqrt(n))
    return (m, sd, half, n)


def cv_percent(x: Sequence[float]) -> float:
    """Coefficient de variation (%) = écart-type / moyenne."""
    m, sd, _, n = mean_ci(x)
    if n < 2 or not m:
        return math.nan
    return abs(sd / m) * 100.0


def bootstrap_ratio_ci(a: Sequence[float], b: Sequence[float], conf: float = 0.95,
                       n_boot: int = 4000, seed: int = 0) -> tuple[float, float, float]:
    """Variation relative (b/a - 1) en % avec IC bootstrap percentile.

    a = référence, b = condition testée. Rééchantillonne chaque groupe indépendamment.
    """
    a = np.asarray(a, float)
    b = np.asarray(b, float)
    a = a[~np.isnan(a)]
    b = b[~np.isnan(b)]
    if len(a) < 2 or len(b) < 2 or a.mean() == 0:
        return (math.nan, math.nan, math.nan)
    rng = np.random.default_rng(seed)
    ia = rng.integers(0, len(a), (n_boot, len(a)))
    ib = rng.integers(0, len(b), (n_boot, len(b)))
    ma = a[ia].mean(axis=1)
    mb = b[ib].mean(axis=1)
    ok = ma != 0
    ratio = (mb[ok] / ma[ok] - 1.0) * 100.0
    lo, hi = np.percentile(ratio, [(1 - conf) / 2 * 100, (1 + conf) / 2 * 100])
    point = (b.mean() / a.mean() - 1.0) * 100.0
    return (float(point), float(lo), float(hi))


def wilson_ci(k: int, n: int, conf: float = 0.95) -> tuple[float, float, float]:
    """Proportion k/n avec intervalle de Wilson (adapté aux petits échantillons)."""
    if n == 0:
        return (math.nan, math.nan, math.nan)
    z = sps.norm.ppf(0.5 + conf / 2)
    p = k / n
    den = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return (p, max(0.0, centre - half), min(1.0, centre + half))


def min_detectable_diff_percent(x: Sequence[float], conf: float = 0.95) -> float:
    """Plus petit écart relatif (%) distinguable du bruit entre deux groupes de même taille n et même variance.

    Approximation : t * sd * sqrt(2/n) / moyenne. Sert à juger si une différence observée est plausiblement du bruit.
    """
    m, sd, _, n = mean_ci(x, conf)
    if n < 2 or not m:
        return math.nan
    t = sps.t.ppf(0.5 + conf / 2, 2 * n - 2)
    return float(abs(t * sd * math.sqrt(2.0 / n) / m) * 100.0)


def drift_spearman(order: Sequence[float], values: Sequence[float]) -> tuple[float, float]:
    """Corrélation de Spearman entre l'ordre d'exécution et la mesure (détecte une dérive thermique/temporelle)."""
    o = np.asarray(order, float)
    v = np.asarray(values, float)
    ok = ~np.isnan(v)
    if ok.sum() < 4:
        return (math.nan, math.nan)
    rho, p = sps.spearmanr(o[ok], v[ok])
    return (float(rho), float(p))
