#!/usr/bin/env bash
# STEP 4 (optional): starts ComfyUI (image generation).
#
#     ./4-comfyui.sh          # starts
#     ./4-comfyui.sh stop     # stops (frees the VRAM)
#
# ComfyUI takes a lot of VRAM: it is NOT started by ./3-demarrer.sh. `lab mode images` does the same and more.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/comfyui"

docker info >/dev/null 2>&1 || { echo "Docker does not answer (see ./1-prerequis.sh)." >&2; exit 1; }

if [ "${1:-}" = "stop" ]; then
  docker compose down
  echo "ComfyUI stopped."
  exit 0
fi

docker network inspect ai-stack_ai-net >/dev/null 2>&1 || {
  echo "The stack's network does not exist: run ./3-demarrer.sh first" >&2; exit 1; }

mkdir -p data/models data/input data/output
# The folders must belong to your user (the container runs with PUID/PGID)
printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" > .env

# Ollama keeps its model in VRAM (OLLAMA_KEEP_ALIVE): unload it to make room
echo "→ Unloading the Ollama models (frees the VRAM)..."
for m in $(docker exec ollama ollama ps 2>/dev/null | awk 'NR>1 {print $1}'); do
  docker exec ollama ollama stop "$m" || true
done

docker compose up -d
cat <<'MSG'

ComfyUI: http://127.0.0.1:8188   (the first start can take several minutes)

At least ONE image model is needed. Put a .safetensors file in:
    comfyui/data/models/checkpoints/
(or use ComfyUI's model manager), then restart: ./4-comfyui.sh

Then, connecting it to Open WebUI: see README, section "Images (ComfyUI)".
MSG
