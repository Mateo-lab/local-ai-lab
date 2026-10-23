"""Runs the tests without pytest: python tests/run_tests.py"""
import sys, traceback
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import test_pipeline as T
fails = 0
for n in sorted(x for x in dir(T) if x.startswith("test_")):
    try:
        getattr(T, n)(); print("OK  ", n)
    except Exception:
        fails += 1; print("FAIL", n); traceback.print_exc()
sys.exit(1 if fails else 0)
