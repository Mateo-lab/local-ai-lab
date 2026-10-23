import json, os, sys, tempfile
from pathlib import Path
os.environ["LABBENCH_FAKE_GPU"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import pandas as pd
from fake_ollama import make_server
from labbench import gpu as G, stats
from labbench.config import load_experiment, plan_runs
from labbench.runner import run_experiment
from labbench.report import build_report


def _run(yaml_text, name):
    d = Path(tempfile.mkdtemp())
    y = d / f"{name}.yaml"; y.write_text(yaml_text)
    gpu = G.open_gpu(); srv = make_server(gpu)
    exp = load_experiment(y, "fake:1b")
    out = run_experiment(exp, gpu, d / "res", mode="external", external_url=f"http://127.0.0.1:{srv.server_port}", log=lambda m: None)
    srv.shutdown()
    return gpu, exp, out


def test_power_sweep_detects_loss():
    gpu, exp, out = _run("""
name: t
repetitions: 4
warmup: 1
idle_s: 1
cooldown: {target_c: 999, max_wait_s: 1}
request: {num_ctx: 8192, ctx_depth: 400, gen_tokens: 40}
factors: {power_limit_w: [350, 200]}
""", "t")
    assert abs(gpu.limit - 350) < 1e-6          # original limit restored
    df = pd.read_csv(out / "runs.csv")
    assert len(df) == 8 and (df.n_ok == 1).all()
    a = df[df.power_limit_w == 350].decode_tps.mean(); b = df[df.power_limit_w == 200].decode_tps.mean()
    assert b < a * 0.7, (a, b)                  # the loss is measured
    assert (df[df.power_limit_w == 200].avg_power_w <= 201).all()
    rep = build_report(out)
    html = rep.read_text()
    assert "Variation from the baseline" in html and "data:image/png" in html
    cmp = pd.read_csv(out / "comparisons.csv")
    row = cmp[cmp.power_limit_w == 200].iloc[0]
    assert row.decode_tps_pct < -20 and bool(row.decode_tps_sig)


def test_resume_skips_done():
    d = Path(tempfile.mkdtemp())
    y = d / "r.yaml"; y.write_text("name: r\nrepetitions: 3\nwarmup: 0\nidle_s: 0\ncooldown: {target_c: 999, max_wait_s: 1}\nrequest: {num_ctx: 8192, ctx_depth: 200, gen_tokens: 8}\nfactors: {gen_tokens: [8, 16]}\n")
    gpu = G.open_gpu(); srv = make_server(gpu); url = f"http://127.0.0.1:{srv.server_port}"
    exp = load_experiment(y, "fake:1b"); out = d / "res"
    run_experiment(exp, gpu, out, mode="external", external_url=url, log=lambda m: None)
    n1 = len(pd.read_csv(out / "runs.csv"))
    (out / "runs.csv").write_text("".join(open(out / "runs.csv").readlines()[:4]))   # simulates an interruption
    run_experiment(exp, gpu, out, mode="external", external_url=url, log=lambda m: None)
    df = pd.read_csv(out / "runs.csv"); srv.shutdown()
    assert n1 == 6 and len(df) == 6 and df.run_id.is_unique


def test_needle_and_prefix_cache():
    _, _, out = _run("""
name: n
repetitions: 3
warmup: 0
idle_s: 0
cooldown: {target_c: 999, max_wait_s: 1}
request: {num_ctx: 8192, ctx_depth: 1500, gen_tokens: 16}
workload: needle
factors: {needle_depth: [0.2, 0.8]}
""", "n")
    df = pd.read_csv(out / "runs.csv"); assert (df.quality == 1.0).all()
    _, _, out = _run("""
name: p
repetitions: 3
warmup: 0
idle_s: 0
cooldown: {target_c: 999, max_wait_s: 1}
request: {num_ctx: 8192, ctx_depth: 2000, gen_tokens: 16}
workload: prefix_cache
factors: {ctx_depth: [2000]}
""", "p")
    df = pd.read_csv(out / "runs.csv"); assert (df.cache_reuse_frac > 0.5).all() and (df.cache_ttft_speedup > 1).all()


def test_concurrency_and_plan():
    _, exp, out = _run("""
name: c
repetitions: 2
warmup: 0
idle_s: 0
cooldown: {target_c: 999, max_wait_s: 1}
request: {num_ctx: 8192, ctx_depth: 300, gen_tokens: 16}
workload: concurrency
factors: {clients: [1, 3]}
""", "c")
    df = pd.read_csv(out / "runs.csv"); assert set(df.clients) == {1, 3} and (df.agg_tps > 0).all()
    assert len(plan_runs(exp)) == 4


def test_stats():
    m, sd, h, n = stats.mean_ci([10, 11, 9, 10.5, 10.2]); assert n == 5 and 9 < m < 11 and h > 0
