#!/usr/bin/env bash
# STEP 7 (optional): scientific benchmark bench (speed, KV cache, context, GPU power limit).
#
#     ./7-bench.sh check                         # checks GPU, sudo, Docker
#     ./7-bench.sh list                          # available experiments
#     ./7-bench.sh run quick-smoke --model qwen3.8:27b     # quick test (~5 min)
#     ./7-bench.sh run power-sweep --model qwen3.8:27b     # performance loss / power curve
#     ./7-bench.sh run power-sweep --dry-run     # shows the plan without running anything
#     ./7-bench.sh report bench/results/<folder>           # rebuilds the report
#
# During a test, the production Ollama is stopped (Open WebUI / Hermes have no model) then restarted.
# Run nothing else on the GPU meanwhile. Method: bench/README.md
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/bench"

cmd="${1:-help}"; shift || true
case "$cmd" in help|-h|--help|"")
  sed -n '2,11p' ../7-bench.sh | sed 's/^# \{0,1\}//'; exit 0;; esac

# --- isolated Python environment (created once) ---
if [ ! -x .venv/bin/python ]; then
  python3 -c 'import venv, ensurepip' 2>/dev/null || {
    echo "The venv module is missing: sudo apt install -y python3-venv   then run again." >&2; exit 1; }
  echo "→ Creating the Python environment (once)..."
  python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt
fi
PY=.venv/bin/python

case "$cmd" in
  list|check|report) exec $PY -m labbench "$cmd" "$@" ;;
  run)
    docker info >/dev/null 2>&1 || { echo "Docker does not answer (see ./1-prerequis.sh)." >&2; exit 1; }
    dry=0; ext=0
    for a in "$@"; do [ "$a" = "--dry-run" ] && dry=1; [ "$a" = "--url" ] && ext=1; done
    if [ $dry -eq 0 ]; then
      if [ $ext -eq 0 ]; then
        docker volume inspect ai-stack_ollama_data >/dev/null 2>&1 || {
          echo "Model volume 'ai-stack_ollama_data' not found (has ai-stack ever run?)." >&2
          echo "Another name? Add --volume NAME (see: docker volume ls)." >&2; exit 1; }
        echo "This test stops the production Ollama for its duration (restarted at the end)."
        echo "Pause: ComfyUI, Hermes, any generation in progress."
      fi
      echo "Administrator rights are needed to set the GPU power limit."
      sudo -v
      read -r -p "Run? [y/N] " ok; [[ "$ok" =~ ^([yYoO]|yes|oui)$ ]] || { echo "Cancelled."; exit 0; }
    fi
    exec $PY -m labbench run "$@" ;;
  *) echo "Unknown command: $cmd (see ./7-bench.sh help)" >&2; exit 1 ;;
esac
