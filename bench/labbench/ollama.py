"""Ollama client (streaming, fine-grained measurements) + management of the test server.

Two modes:
  - managed  : the bench starts its own 'ollama-bench' container (port 127.0.0.1:11435), with the
               environment variables of the current block (KV cache, flash attention, parallelism).
               The production Ollama ('ollama') is stopped during the test, then restarted at the end.
  - external : an existing Ollama is measured as is (the "server" factors cannot vary).
"""
from __future__ import annotations

import json
import re
import subprocess
import time
from dataclasses import dataclass, field

import requests

BENCH_CONTAINER = "ollama-bench"
PROD_CONTAINER = "ollama"


@dataclass
class GenResult:
    ok: bool
    error: str = ""
    ttft_s: float = float("nan")          # time to the 1st token (answer or "thinking")
    total_s: float = float("nan")         # total client-side duration
    prompt_tokens: int = 0
    gen_tokens: int = 0
    prompt_eval_s: float = float("nan")   # measured by Ollama
    eval_s: float = float("nan")
    load_s: float = float("nan")
    itl_ms: list = field(default_factory=list)   # latences inter-chunks (ms)
    text: str = ""
    thinking: str = ""

    @property
    def prefill_tps(self) -> float:
        return self.prompt_tokens / self.prompt_eval_s if self.prompt_eval_s and self.prompt_eval_s > 0 else float("nan")

    @property
    def decode_tps(self) -> float:
        return self.gen_tokens / self.eval_s if self.eval_s and self.eval_s > 0 else float("nan")


class OllamaClient:
    def __init__(self, base_url: str):
        self.url = base_url.rstrip("/")

    def wait_ready(self, timeout_s: float = 90) -> None:
        t0 = time.time()
        while time.time() - t0 < timeout_s:
            try:
                if requests.get(f"{self.url}/api/version", timeout=3).ok:
                    return
            except requests.RequestException:
                pass
            time.sleep(1)
        raise RuntimeError(f"Ollama does not answer on {self.url}")

    def version(self) -> str:
        return requests.get(f"{self.url}/api/version", timeout=10).json().get("version", "?")

    def ps(self) -> list[dict]:
        return requests.get(f"{self.url}/api/ps", timeout=10).json().get("models", [])

    def show(self, model: str) -> dict:
        r = requests.post(f"{self.url}/api/show", json={"model": model}, timeout=30)
        r.raise_for_status()
        return r.json()

    def unload(self, model: str) -> None:
        try:
            requests.post(f"{self.url}/api/generate", json={"model": model, "keep_alive": 0}, timeout=60)
        except requests.RequestException:
            pass

    def placement(self, model: str) -> dict:
        """Share of the model in VRAM + effective context, according to /api/ps."""
        for m in self.ps():
            if m.get("name") == model or m.get("model") == model:
                size, vram = m.get("size", 0), m.get("size_vram", 0)
                return {"size_mb": size / 2**20, "vram_mb": vram / 2**20,
                        "gpu_frac": (vram / size) if size else float("nan"),
                        "ctx": m.get("context_length", None)}
        return {"size_mb": float("nan"), "vram_mb": float("nan"), "gpu_frac": float("nan"), "ctx": None}

    def generate(self, model: str, prompt: str, *, num_ctx: int, num_predict: int, think: bool = False,
                 temperature: float = 0.0, seed: int = 1, keep_alive: str = "30m",
                 timeout_s: float = 900, system: str | None = None) -> GenResult:
        body = {"model": model, "prompt": prompt, "stream": True, "think": bool(think),
                "keep_alive": keep_alive,
                "options": {"num_ctx": int(num_ctx), "num_predict": int(num_predict),
                            "temperature": temperature, "seed": seed}}
        if system:
            body["system"] = system
        res = GenResult(ok=False)
        t0 = time.perf_counter()
        last = None
        try:
            with requests.post(f"{self.url}/api/generate", json=body, stream=True, timeout=(10, timeout_s)) as r:
                if r.status_code != 200:
                    res.error = f"HTTP {r.status_code}: {r.text[:200]}"
                    return res
                for line in r.iter_lines():
                    if not line:
                        continue
                    d = json.loads(line)
                    if d.get("error"):
                        res.error = str(d["error"])
                        return res
                    now = time.perf_counter()
                    piece, think_piece = d.get("response", ""), d.get("thinking", "")
                    if piece or think_piece:
                        if last is None:
                            res.ttft_s = now - t0
                        else:
                            res.itl_ms.append((now - last) * 1000.0)
                        last = now
                        res.text += piece
                        res.thinking += think_piece
                    if d.get("done"):
                        res.prompt_tokens = int(d.get("prompt_eval_count", 0))
                        res.gen_tokens = int(d.get("eval_count", 0))
                        res.prompt_eval_s = d.get("prompt_eval_duration", 0) / 1e9
                        res.eval_s = d.get("eval_duration", 0) / 1e9
                        res.load_s = d.get("load_duration", 0) / 1e9
            res.total_s = time.perf_counter() - t0
            res.ok = True
        except requests.RequestException as e:
            res.error = f"{type(e).__name__}: {e}"
        return res


def _sh(cmd: list[str], check=True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


class ManagedServer:
    """Ollama container dedicated to the bench, restarted with each block's environment."""

    def __init__(self, image: str, volume: str, port: int = 11435, gpu_index: int = 0):
        self.image, self.volume, self.port, self.gpu_index = image, volume, port, gpu_index
        self.prod_was_running = False

    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def prepare(self) -> None:
        r = _sh(["docker", "ps", "--format", "{{.Names}}"], check=False)
        if r.returncode != 0:
            raise RuntimeError("Docker unreachable: " + r.stderr.strip())
        self.prod_was_running = PROD_CONTAINER in r.stdout.split()
        if self.prod_was_running:
            print("  - temporarily stopping the production Ollama (restarted at the end of the test)")
            _sh(["docker", "stop", PROD_CONTAINER])
        self.stop()

    def start(self, env: dict[str, str]) -> OllamaClient:
        self.stop()
        cmd = ["docker", "run", "-d", "--name", BENCH_CONTAINER, "--gpus", f"device={self.gpu_index}",
               "-v", f"{self.volume}:/root/.ollama", "-p", f"127.0.0.1:{self.port}:11434",
               "-e", "OLLAMA_HOST=0.0.0.0:11434", "-e", "OLLAMA_MAX_LOADED_MODELS=1"]
        for k, v in env.items():
            cmd += ["-e", f"{k}={v}"]
        cmd.append(self.image)
        _sh(cmd)
        cli = OllamaClient(self.url())
        cli.wait_ready()
        return cli

    def log_excerpt(self, max_lines: int = 80) -> str:
        """Useful lines of the server log (parallelism, context, layers on GPU, memory): makes it possible to check
        that the requested settings (e.g. OLLAMA_NUM_PARALLEL) were really applied by Ollama."""
        r = _sh(["docker", "logs", "--tail", "800", BENCH_CONTAINER], check=False)
        text = (r.stdout or "") + (r.stderr or "")
        keep = re.compile(r"(?i)parallel|num_ctx|n_ctx|kvsize|kv cache|offload|layers|memory|--ctx-size|runner|flash|cache_type")
        return "\n".join([ln for ln in text.splitlines() if keep.search(ln)][-max_lines:])

    def stop(self) -> None:
        _sh(["docker", "rm", "-f", BENCH_CONTAINER], check=False)

    def restore(self) -> None:
        self.stop()
        if self.prod_was_running:
            print("  - restarting the production Ollama")
            _sh(["docker", "start", PROD_CONTAINER], check=False)


def server_env(values: dict) -> dict[str, str]:
    """Translates the "server" factors into Ollama environment variables."""
    return {
        "OLLAMA_KV_CACHE_TYPE": str(values.get("kv_cache_type", "f16")),
        "OLLAMA_FLASH_ATTENTION": str(int(values.get("flash_attention", 1))),
        "OLLAMA_NUM_PARALLEL": str(int(values.get("num_parallel", 1))),
        "OLLAMA_KEEP_ALIVE": str(values.get("keep_alive", "30m")),
    }
