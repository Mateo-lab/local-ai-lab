"""Statistical analysis + HTML report (tables, CIs, comparisons with the baseline, charts, warnings)."""
from __future__ import annotations

import base64
import html
import io
import json
import math
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from . import stats as S

METRICS = [  # (column, label, "higher = better"?)
    ("decode_tps", "Generation (tok/s)", True),
    ("prefill_tps", "Prefill (tok/s)", True),
    ("ttft_s", "TTFT (s)", False),
    ("itl_p95_ms", "Inter-token latency p95 (ms)", False),
    ("agg_tps", "Aggregate throughput (tok/s)", True),
    ("avg_power_w", "Mean power (W)", None),
    ("j_per_token", "Energy (J/token)", False),
    ("tokens_per_j", "Efficiency (tok/J)", True),
    ("avg_sm_mhz", "SM clock (MHz)", None),
    ("max_temp_c", "Max temperature (°C)", None),
    ("thr_power_frac", "Share of time capped by the power limit", None),
    ("thr_thermal_frac", "Share of time thermally throttled", None),
    ("quality", "Quality (success rate)", True),
    ("cache_ttft_speedup", "TTFT speed-up (prefix cache)", True),
    ("cache_reuse_frac", "Share of the prefix reused", True),
    ("gpu_frac", "Share of the model in VRAM", True),
    ("peak_mem_used_mb", "VRAM used on the card, peak (MB)", None),
]
KEY = ["decode_tps", "prefill_tps", "ttft_s", "avg_power_w", "j_per_token"]


def load(outdir: Path):
    df = pd.read_csv(outdir / "runs.csv")
    exp = json.loads((outdir / "experiment.json").read_text())
    meta = json.loads((outdir / "meta.json").read_text()) if (outdir / "meta.json").exists() else {}
    return df, exp, meta


def _png(fig) -> str:
    b = io.BytesIO()
    fig.savefig(b, format="png", dpi=110, bbox_inches="tight")
    plt.close(fig)
    return "data:image/png;base64," + base64.b64encode(b.getvalue()).decode()


def _f(x, nd=2):
    return "—" if x is None or (isinstance(x, float) and math.isnan(x)) else f"{x:.{nd}f}"


def summary_table(df: pd.DataFrame, factors: list[str]) -> pd.DataFrame:
    rows = []
    keys = factors if factors else ["cid"]
    for gk, g in df[df.n_ok > 0].groupby(keys, dropna=False, sort=False):
        gk = gk if isinstance(gk, tuple) else (gk,)
        row = dict(zip(keys, gk))
        row["n"] = len(g)
        for col, _, _ in METRICS:
            if col in g and g[col].notna().any():
                m, sd, half, n = S.mean_ci(g[col].tolist())
                row[col] = m; row[col + "_ci"] = half; row[col + "_cv"] = S.cv_percent(g[col].tolist())
        rows.append(row)
    d = pd.DataFrame(rows)
    return d.sort_values(keys).reset_index(drop=True) if len(d) else d


def baseline_mask(df: pd.DataFrame, exp: dict, factors: list[str]) -> pd.Series:
    """Baseline condition: values given in 'baseline:', otherwise the 1st listed value of each factor."""
    m = pd.Series(True, index=df.index)
    for f in factors:
        ref = exp.get("baseline", {}).get(f, exp["factors"][f][0])
        m &= df[f].astype(str) == str(ref)
    return m


def comparisons(df: pd.DataFrame, exp: dict, factors: list[str]) -> pd.DataFrame:
    base = df[baseline_mask(df, exp, factors) & (df.n_ok > 0)]
    out = []
    keys = factors
    for gk, g in df[df.n_ok > 0].groupby(keys, dropna=False, sort=False):
        gk = gk if isinstance(gk, tuple) else (gk,)
        row = dict(zip(keys, gk))
        row["n"] = len(g)
        for col in ("decode_tps", "prefill_tps", "ttft_s", "avg_power_w", "j_per_token", "quality"):
            if col not in g or base.empty or not g[col].notna().any():
                continue
            pt, lo, hi = S.bootstrap_ratio_ci(base[col].tolist(), g[col].tolist())
            row[col + "_pct"], row[col + "_lo"], row[col + "_hi"] = pt, lo, hi
            row[col + "_sig"] = (not math.isnan(lo)) and (lo > 0 or hi < 0)
        out.append(row)
    d = pd.DataFrame(out)
    return d.sort_values(keys).reset_index(drop=True) if len(d) else d


def diagnostics(df: pd.DataFrame, exp: dict, meta: dict, factors: list[str]) -> list[tuple[str, str]]:
    """Validity warnings (level, text)."""
    w: list[tuple[str, str]] = []
    good = df[df.n_ok > 0]
    n_fail = int((df.n_err > 0).sum()) if "n_err" in df else 0
    if n_fail:
        w.append(("warn", f"{n_fail} measurement(s) with an error — see the 'error' column of runs.csv."))
    reps = good.groupby("cid").size()
    if len(reps) and reps.min() < 5:
        w.append(("warn", f"Only {int(reps.min())} repetition(s) per condition: the confidence intervals are wide. "
                          "Aim for ≥ 5 (≥ 10 to tell apart differences < 3 %)."))
    # bruit
    for col in ("decode_tps",):
        if col in good and len(good):
            cvs = [S.cv_percent(g[col].tolist()) for _, g in good.groupby("cid")]
            cvs = [c for c in cvs if not math.isnan(c)]
            if cvs:
                mdds = [S.min_detectable_diff_percent(g[col].tolist()) for _, g in good.groupby("cid")]
                mdds = [x for x in mdds if not math.isnan(x)]
                w.append(("info", f"Measurement noise on {col}: median CV {np.median(cvs):.1f} %, "
                                   f"smallest detectable difference ≈ {np.median(mdds):.1f} % (95 %). "
                                   "A difference below this value cannot be told apart from noise."))
                if max(cvs) > 5:
                    w.append(("warn", f"CV > 5 % on at least one condition ({max(cvs):.1f} %): machine not isolated "
                                       "(other GPU load? Open WebUI/Hermes active?) or unstable temperature."))
    # drift
    if "decode_tps" in good and len(good) >= 8:
        rho, p = S.drift_spearman(good.seq.tolist(), good.decode_tps.tolist())
        if not math.isnan(p) and p < 0.05 and abs(rho) > 0.3:
            w.append(("warn", f"Temporal drift detected (Spearman ρ={rho:.2f}, p={p:.3f}) between run order and speed: "
                              "risk of thermal confounding. The randomised plan limits the effect, but increase the cool-down."))
    # thermique / throttling
    if "thr_thermal_frac" in good and good.thr_thermal_frac.max() > 0.05:
        w.append(("warn", f"Thermal throttling observed (up to {good.thr_thermal_frac.max() * 100:.0f} % of the time). "
                          "The differences then mix power limit and heat."))
    if "thr_hw_frac" in good and good.thr_hw_frac.max() > 0.01:
        w.append(("bad", "Hardware slowdown (HW slowdown / power brake) detected: check the power supply or the cooling."))
    if "gpu_frac" in good and good.gpu_frac.min() < 0.99:
        w.append(("warn", f"The model is not 100 % in VRAM in some conditions (min {good.gpu_frac.min() * 100:.0f} %): "
                          "CPU spill-over, the differences mostly reflect that spill-over."))
    if exp.get("workload") in ("needle", "arith", "arith_easy") and "quality" in good:
        n_q = int(good.groupby("cid").size().min())
        w.append(("info", f"Quality: proportions with a Wilson interval; with {n_q} trials per condition, "
                          "only large differences (≳ 30 points) are detectable."))
    if meta.get("idle"):
        w.append(("info", f"Measured idle power: {_f(meta['idle'].get('avg_power_w'), 1)} W "
                          "(not subtracted from J/token: they include the GPU's idle cost)."))
    return w


def _plot_factor(df, exp, factors, x, ycol, ylabel, group):
    fig, ax = plt.subplots(figsize=(6.2, 3.8))
    g_cols = [f for f in group if f != x]
    for gk, sub in (df.groupby(g_cols, dropna=False, sort=False) if g_cols else [("", df)]):
        xs, ys, es = [], [], []
        for xv, s in sub.groupby(x, sort=True):
            m, sd, half, n = S.mean_ci(s[ycol].tolist())
            xs.append(xv); ys.append(m); es.append(0 if math.isnan(half) else half)
        label = ", ".join(f"{c}={v}" for c, v in zip(g_cols, gk if isinstance(gk, tuple) else (gk,))) if g_cols else ycol
        ax.errorbar(xs, ys, yerr=es, marker="o", capsize=3, label=label)
    ax.set_xlabel(x); ax.set_ylabel(ylabel); ax.grid(alpha=.3)
    if g_cols:
        ax.legend(fontsize=7)
    return _png(fig)


def _plot_pareto(df):
    fig, ax = plt.subplots(figsize=(6.2, 3.8))
    for pl, s in df.groupby("power_limit_w"):
        ax.errorbar(s.j_per_token.mean(), s.decode_tps.mean(), yerr=S.mean_ci(s.decode_tps.tolist())[2] or 0,
                    xerr=S.mean_ci(s.j_per_token.tolist())[2] or 0, marker="o", capsize=3)
        ax.annotate(f"{pl:.0f} W", (s.j_per_token.mean(), s.decode_tps.mean()), textcoords="offset points", xytext=(5, 5), fontsize=8)
    ax.set_xlabel("Energy (J/token) — lower = better"); ax.set_ylabel("Generation (tok/s)"); ax.grid(alpha=.3)
    return _png(fig)


def _plot_timeline(outdir: Path):
    p = outdir / "telemetry.csv"
    if not p.exists():
        return None
    t = pd.read_csv(p)
    if t.empty:
        return None
    x = t.t - t.t.iloc[0]
    fig, axs = plt.subplots(3, 1, figsize=(8, 5.5), sharex=True)
    axs[0].plot(x, t.power_w, lw=.7); axs[0].set_ylabel("W")
    axs[1].plot(x, t.temp_c, lw=.7, color="C3"); axs[1].set_ylabel("°C")
    axs[2].plot(x, t.sm_mhz, lw=.7, color="C2"); axs[2].set_ylabel("SM MHz"); axs[2].set_xlabel("s")
    for a in axs:
        a.grid(alpha=.3)
    return _png(fig)


def _table_html(df: pd.DataFrame, cols: list[tuple[str, str]], ci: bool = True) -> str:
    h = "<table><tr>" + "".join(f"<th>{html.escape(l)}</th>" for _, l in cols) + "</tr>"
    for _, r in df.iterrows():
        h += "<tr>"
        for c, _ in cols:
            v = r.get(c)
            if c == "n":
                h += f"<td>{int(v)}</td>"
            elif isinstance(v, (float, np.floating)):
                txt = _f(float(v), 3 if abs(v) < 1 else 1 if abs(v) > 100 else 2)
                if ci and c + "_ci" in r and not pd.isna(r[c + "_ci"]):
                    txt += f" ± {_f(float(r[c + '_ci']), 2)}"
                h += f"<td>{txt}</td>"
            else:
                h += f"<td>{html.escape(str(v))}</td>"
        h += "</tr>"
    return h + "</table>"


def _cmp_html(cmp: pd.DataFrame, factors: list[str]) -> str:
    cols = [("decode_tps", "Generation"), ("prefill_tps", "Prefill"), ("ttft_s", "TTFT"),
            ("avg_power_w", "Power"), ("j_per_token", "J/token"), ("quality", "Quality")]
    h = "<table><tr>" + "".join(f"<th>{html.escape(f)}</th>" for f in factors) + "<th>n</th>" + \
        "".join(f"<th>{l} (Δ%, IC95)</th>" for c, l in cols if c + "_pct" in cmp) + "</tr>"
    for _, r in cmp.iterrows():
        h += "<tr>" + "".join(f"<td>{html.escape(str(r[f]))}</td>" for f in factors) + f"<td>{int(r['n'])}</td>"
        for c, _ in cols:
            if c + "_pct" not in cmp:
                continue
            pt = r[c + "_pct"]
            if pd.isna(pt):
                h += "<td>—</td>"; continue
            sig = bool(r[c + "_sig"])
            h += f"<td class='{'sig' if sig else 'ns'}'>{pt:+.1f} % [{r[c + '_lo']:+.1f} ; {r[c + '_hi']:+.1f}]{' *' if sig else ''}</td>"
        h += "</tr>"
    return h + "</table>"


CSS = """body{font-family:system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#222}
table{border-collapse:collapse;margin:1rem 0;font-size:.85rem}td,th{border:1px solid #ccc;padding:.3rem .5rem;text-align:right}
th{background:#f3f3f3}td:first-child,th:first-child{text-align:left}.sig{background:#e6f4ea}.ns{color:#777}
.warn{background:#fff4d6;padding:.4rem .7rem;margin:.3rem 0;border-left:4px solid #e0a800}
.bad{background:#fde2e2;padding:.4rem .7rem;margin:.3rem 0;border-left:4px solid #c00}
.info{background:#e8f1fb;padding:.4rem .7rem;margin:.3rem 0;border-left:4px solid #3b82c4}
img{max-width:100%}.grid{display:flex;flex-wrap:wrap;gap:1rem}small{color:#666}"""


def build_report(outdir: Path) -> Path:
    df, exp, meta = load(outdir)
    factors = list(exp["factors"])
    out = ["<html><head><meta charset='utf-8'><title>Benchmark report</title><style>" + CSS + "</style></head><body>"]
    out.append(f"<h1>{html.escape(exp['name'])}</h1>")
    g = meta.get("gpu", {})
    out.append(f"<p><b>Model</b>: {html.escape(str(exp['model']))} · <b>GPU</b>: {html.escape(str(g.get('name', '?')))} "
               f"(driver {g.get('driver', '?')}, original limit {_f(meta.get('original_power_limit_w'), 0)} W) · "
               f"<b>Ollama</b> {meta.get('ollama_version', '?')} · workload: {exp['workload']} · "
               f"{len(df)} measurements · started {meta.get('started', '?')}</p>")
    out.append("<h2>Validity of the experiment</h2>")
    for lvl, txt in diagnostics(df, exp, meta, factors):
        out.append(f"<div class='{lvl}'>{html.escape(txt)}</div>")

    good = df[df.n_ok > 0].copy()
    if good.empty:
        out.append("<div class='bad'>No valid measurement.</div></body></html>")
        p = outdir / "report.html"; p.write_text("".join(out)); return p
    summ = summary_table(good, factors)
    summ.to_csv(outdir / "summary.csv", index=False)
    cols = [(f, f) for f in factors] + [("n", "n")] + [(c, l) for c, l, _ in METRICS if c in summ and c in
                                                       ("decode_tps", "prefill_tps", "ttft_s", "itl_p95_ms", "agg_tps", "avg_power_w", "j_per_token",
                                                        "avg_sm_mhz", "max_temp_c", "thr_power_frac", "quality", "cache_ttft_speedup", "gpu_frac")]
    out.append("<h2>Results per condition</h2><small>mean ± half-width of the 95 % CI (Student)</small>")
    out.append(_table_html(summ, cols))
    if factors:
        cmp = comparisons(good, exp, factors)
        cmp.to_csv(outdir / "comparisons.csv", index=False)
        ref = {f: exp.get("baseline", {}).get(f, exp["factors"][f][0]) for f in factors}
        out.append(f"<h2>Variation from the baseline</h2><small>baseline = {html.escape(str(ref))} · "
                   "Δ% with bootstrap 95% CI · green background/* = the CI excludes 0 (difference statistically distinct from noise)</small>")
        out.append(_cmp_html(cmp, factors))
    # charts
    imgs = []
    num = [f for f in factors if pd.api.types.is_numeric_dtype(good[f]) and good[f].nunique() > 1]
    x = exp.get("report", {}).get("x") or (num[0] if num else (factors[0] if factors else None))
    if x and x in good:
        for col, lab, _ in METRICS:
            if col in ("decode_tps", "prefill_tps", "ttft_s", "avg_power_w", "j_per_token", "avg_sm_mhz", "max_temp_c",
                       "quality", "agg_tps", "cache_ttft_speedup") and col in good and good[col].notna().any() \
                    and good[x].nunique() > 1:
                imgs.append(_plot_factor(good, exp, factors, x, col, lab, factors))
    if "power_limit_w" in factors and good.power_limit_w.nunique() > 1 and good.j_per_token.notna().any():
        imgs.append(_plot_pareto(good))
    tl = _plot_timeline(outdir)
    if tl:
        imgs.append(tl)
    if imgs:
        out.append("<h2>Charts</h2><div class='grid'>" + "".join(f"<img src='{i}'>" for i in imgs) + "</div>")
    out.append("<h2>Method</h2><small>Plan " + html.escape(str(exp["design"])) + f", seed {exp['seed']}, {exp['repetitions']} repetitions, "
               f"{exp['warmup']} warm-up(s) per block, cool-down to {exp['cooldown']['target_c']} °C before each measurement. "
               "Energy = NVML hardware counter (not an integral of samples). The prompts carry a nonce: no reuse "
               "of the prefix cache except for the prefix_cache workload. Raw values are in runs.csv and telemetry.csv.</small>")
    out.append("</body></html>")
    p = outdir / "report.html"
    p.write_text("".join(out), encoding="utf-8")
    return p
