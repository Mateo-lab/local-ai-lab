#!/usr/bin/env bash
# STEP 3: starts the stack (Ollama, Open WebUI, n8n, Postgres, Qdrant) and monitoring.
#
#     ./3-demarrer.sh                    # starts everything
#     ./3-demarrer.sh MODEL_NAME         # starts everything AND downloads this model (several GB)
#     Without an argument: LAB_MODEL from lab.conf if set, otherwise no download.
#
# OpenClaw is NOT started here: it is installed separately, last (see README).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[ ! -f lab.conf ] || . ./lab.conf
MODEL="${1:-${LAB_MODEL:-}}"

command -v docker >/dev/null 2>&1 || { echo "Docker not found: run ./1-prerequis.sh first" >&2; exit 1; }
if ! docker info >/dev/null 2>&1; then
  echo "Docker does not answer for your user." >&2
  echo "If you just installed it, reboot the machine (sudo reboot) then run this script again." >&2
  exit 1
fi
[ -f ai-stack/.env ] && [ -f monitoring/.env ] || { echo "The .env files are missing: run ./2-secrets.sh first" >&2; exit 1; }

echo "→ Testing the GPU in Docker..."
if ! docker run --rm --gpus all ubuntu nvidia-smi -L; then
  echo >&2
  echo "Docker does not see the graphics card. Run ./1-prerequis.sh again, then reboot the machine." >&2
  exit 1
fi

echo "→ Starting the stack (the first start downloads several images)..."
(cd ai-stack && docker compose up -d)

echo "→ Starting monitoring..."
(cd monitoring && docker compose up -d)

if [ -n "$MODEL" ]; then
  echo "→ Downloading the model $MODEL (be patient)..."
  docker exec ollama ollama pull "$MODEL"
fi

echo
echo "=== State ==="
(cd ai-stack && docker compose ps)
(cd monitoring && docker compose ps)

cat <<'EOF'

Interfaces (reachable ONLY from this machine):
  Open WebUI : http://127.0.0.1:3000
  n8n        : http://127.0.0.1:5678
  Grafana    : http://127.0.0.1:3001   (user: admin)
  Prometheus : http://127.0.0.1:9090

If you work from another computer, open an SSH tunnel from it, for example:
  ssh -L 3000:127.0.0.1:3000 -L 5678:127.0.0.1:5678 -L 3001:127.0.0.1:3001 USER@MACHINE-IP
then open http://127.0.0.1:3000 in your browser. Better: `lab client` generates a ready-made configuration.

No model yet? Download one:
  docker exec -it ollama ollama pull MODEL_NAME      (for example the one in lab.conf)
EOF
