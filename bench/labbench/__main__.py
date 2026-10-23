"""CLI: python -m labbench {check,list,run,report}"""
from __future__ import annotations

import argparse
import datetime as dt
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXPDIR = ROOT / "experiments"
RESDIR = ROOT / "results"


def cmd_list(a):
    for p in sorted(EXPDIR.glob("*.yaml")):
        first = next((l[1:].strip() for l in p.read_text().splitlines() if l.startswith("#")), "")
        print(f"  {p.stem:<18} {first}")


def cmd_check(a):
    from .gpu import open_gpu
    ok = True
    try:
        g = open_gpu()
        i = g.info()
        print(f"GPU            : {i.name} (driver {i.driver})")
        print(f"Limit          : {i.power_limit_w:.0f} W current · default {i.power_default_w:.0f} W · bounds [{i.power_min_w:.0f}; {i.power_max_w:.0f}] W")
        s = g.sample()
        print(f"State          : {s['temp_c']:.0f} °C · {s['power_w']:.0f} W · VRAM used {s['mem_used_mb']:.0f}/{i.mem_total_mb:.0f} MB · "
              f"energy counter {'OK' if s['energy_mj'] == s['energy_mj'] else 'UNAVAILABLE (measurement by integration impossible)'}")
    except Exception as e:
        print("GPU            : ERROR", e); return 1
    r = subprocess.run(["sudo", "-n", "true"], capture_output=True)
    if r.returncode == 0:
        print("sudo           : OK (power limit can be set)")
    else:
        print("sudo           : no cached rights → run 'sudo -v' before a test with power_limit_w"); ok = False
    r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True)
    if r.returncode == 0:
        names = r.stdout.split()
        print(f"Docker         : OK · running containers: {', '.join(names) or 'none'}")
        busy = [n for n in names if n in ("comfyui", "hermes", "open-webui", "ollama-bench")]
        if busy:
            print(f"  ⚠ to stop/avoid during a test (they may use the GPU): {', '.join(busy)}")
    else:
        print("Docker         : unreachable", r.stderr.strip()); ok = False
    return 0 if ok else 1


def cmd_run(a):
    from .config import load_experiment
    from .gpu import open_gpu
    from .runner import run_experiment
    path = Path(a.experiment)
    if not path.exists():
        path = EXPDIR / (a.experiment if a.experiment.endswith((".yaml", ".yml")) else a.experiment + ".yaml")
    exp = load_experiment(path, a.model)
    if a.reps:
        exp.raw["repetitions"] = a.reps
    out = Path(a.resume) if a.resume else RESDIR / f"{exp.name}-{dt.datetime.now():%Y%m%d-%H%M%S}"
    mode = "external" if a.url else "managed"
    out = run_experiment(exp, open_gpu(), out, mode=mode, external_url=a.url, volume=a.volume, port=a.port, dry_run=a.dry_run)
    if not a.dry_run:
        from .report import build_report
        p = build_report(out)
        print(f"\nResults: {out}\nReport : {p}")
    return 0


def cmd_report(a):
    from .report import build_report
    print(build_report(Path(a.dir)))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="labbench", description="Local LLM benchmark bench (Ollama + GPU telemetry)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(f=cmd_list)
    sub.add_parser("check").set_defaults(f=cmd_check)
    r = sub.add_parser("run")
    r.add_argument("experiment")
    r.add_argument("--model")
    r.add_argument("--reps", type=int, help="replaces 'repetitions' from the YAML")
    r.add_argument("--url", help="external mode: measures this Ollama as is (no restart)")
    r.add_argument("--volume", default="ai-stack_ollama_data", help="Docker volume containing the models")
    r.add_argument("--port", type=int, default=11435)
    r.add_argument("--resume", help="results folder to resume")
    r.add_argument("--dry-run", action="store_true", help="shows the plan without running anything")
    r.set_defaults(f=cmd_run)
    p = sub.add_parser("report"); p.add_argument("dir"); p.set_defaults(f=cmd_report)
    a = ap.parse_args(argv)
    return a.f(a) or 0


if __name__ == "__main__":
    sys.exit(main())
