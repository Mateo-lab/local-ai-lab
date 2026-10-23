"""Fake Ollama server to test the bench without a GPU or a model. The speed depends on the FakeGpu's power limit."""
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def make_server(gpu, port=0):
    state = {"last_prompt": "", "active": 0}
    lock = threading.Lock()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass

        def _json(self, obj, code=200):
            b = json.dumps(obj).encode()
            self.send_response(code); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

        def do_GET(self):
            if self.path == "/api/version": return self._json({"version": "0.0-fake"})
            if self.path == "/api/ps":
                return self._json({"models": [{"name": "fake:1b", "model": "fake:1b", "size": 4 << 30, "size_vram": 4 << 30, "context_length": 8192}]})
            self._json({}, 404)

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.path != "/api/generate": return self._json({}, 404)
            prompt = body.get("prompt", "")
            n_pred = body.get("options", {}).get("num_predict", 16)
            if not prompt or body.get("keep_alive") == 0:
                return self._json({"done": True})
            speed = max(0.2, (gpu.limit - 80) / 270)          # 1.0 at 350 W
            ptoks = max(1, len(prompt) // 4)
            common = 0
            for a, b in zip(prompt, state["last_prompt"]):
                if a != b: break
                common += 1
            cached = common // 4 if common > 200 else 0
            state["last_prompt"] = prompt
            with lock:
                state["active"] += 1; gpu.activity = 1.0
            t0 = time.time()
            time.sleep(max(0.0, (ptoks - cached) / (20000 * speed)))
            pe = time.time() - t0
            m = re.search(r"secret code is ([A-Z0-9]{6})", prompt)
            text = (m.group(1) if m else "42") + " lorem" * 5
            self.send_response(200); self.send_header("Content-Type", "application/x-ndjson"); self.end_headers()
            toks = text.split(" ") * 1
            toks = (toks + ["x"] * n_pred)[:max(1, min(n_pred, 40))]
            t1 = time.time()
            for t in toks:
                time.sleep(1 / (300 * speed))
                self.wfile.write((json.dumps({"response": t + " ", "done": False}) + "\n").encode()); self.wfile.flush()
            ed = time.time() - t1
            self.wfile.write((json.dumps({"response": "", "done": True, "prompt_eval_count": ptoks - cached,
                                          "prompt_eval_duration": int(pe * 1e9), "eval_count": len(toks),
                                          "eval_duration": int(ed * 1e9), "load_duration": 0}) + "\n").encode())
            with lock:
                state["active"] -= 1
                if state["active"] == 0: gpu.activity = 0.0

    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv
