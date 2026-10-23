#!/usr/bin/env bash
# Installs OpenClaw with Docker (official pre-built image) and connects it
# to the Ollama of ../ai-stack through the `llm-net` Docker network.
#
# Usage:  ./install.sh
# Optional variables:
#   OPENCLAW_DIR    installation folder (default: ~/openclaw)
#   OPENCLAW_IMAGE  image to use        (default: ghcr.io/openclaw/openclaw:latest)
#                   For the gateway's browser feature: ...:latest-browser
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${OPENCLAW_DIR:-$HOME/openclaw}"
export OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' not found." >&2; exit 1; }; }
need docker
need git
docker compose version >/dev/null 2>&1 || { echo "Error: Docker Compose v2 is required." >&2; exit 1; }

# The llm-net network is created when the ai-stack starts
if ! docker network inspect llm-net >/dev/null 2>&1; then
  echo "Error: the Docker network 'llm-net' does not exist." >&2
  echo "Start the stack first:  cd ../ai-stack && docker compose up -d" >&2
  exit 1
fi

if [ -d "$TARGET/.git" ]; then
  echo "→ OpenClaw repository already present, updating: $TARGET"
  git -C "$TARGET" pull --ff-only
else
  echo "→ Cloning the OpenClaw repository into $TARGET"
  git clone https://github.com/openclaw/openclaw.git "$TARGET"
fi

echo "→ Adding the network override (llm-net)"
cp "$HERE/docker-compose.override.yml" "$TARGET/docker-compose.override.yml"

cd "$TARGET"
echo "→ Image: $OPENCLAW_IMAGE"
echo
echo "The installation wizard is about to start. Answers to give:"
echo "  • Provider: Ollama, mode \"Local only\""
echo "  • Ollama URL: http://ollama:11434   (NOT host.docker.internal)"
echo "  • Model: the one you downloaded (e.g. qwen3.8:27b)"
echo
./scripts/docker/setup.sh

# The official script calls "docker compose -f docker-compose.yml": the override (llm-net network) is then
# ignored. So the gateway is attached to llm-net here (no effect if it already is).
GW="$(docker compose -f docker-compose.yml ps -q openclaw-gateway 2>/dev/null | head -n1)"
if [ -n "$GW" ]; then
  docker network connect llm-net "$GW" 2>/dev/null && echo "→ Gateway attached to llm-net" || true
  if docker network inspect llm-net --format '{{range .Containers}}{{.Id}} {{end}}' | grep -q "${GW:0:12}"; then
    echo "→ OK: the gateway is on llm-net (Ollama reachable at http://ollama:11434)"
  else
    echo "WARNING: the gateway is not on llm-net. Type: docker network connect llm-net \$(docker compose -f $TARGET/docker-compose.yml ps -q openclaw-gateway)" >&2
  fi
fi

# The official compose publishes its ports on ALL interfaces (local network, VPN). Limit them to 127.0.0.1:
# the interface stays reachable from this machine and through the SSH tunnel (see docs/openclaw.md, Security).
if [ -f .env ]; then
  cp .env .env.avant-localhost
  for v in OPENCLAW_GATEWAY_PORT=127.0.0.1:18789 OPENCLAW_BRIDGE_PORT=127.0.0.1:18790 OPENCLAW_MSTEAMS_PORT=127.0.0.1:3978; do
    if grep -q "^${v%%=*}=" .env; then sed -i "s|^${v%%=*}=.*|$v|" .env; else echo "$v" >> .env; fi
  done
  docker compose -f docker-compose.yml up -d openclaw-gateway >/dev/null
  GW="$(docker compose -f docker-compose.yml ps -q openclaw-gateway 2>/dev/null | head -n1)"
  [ -n "$GW" ] && docker network connect llm-net "$GW" 2>/dev/null || true
  echo "→ Ports limited to 127.0.0.1 (18789, 18790, 3978); gateway recreated and attached to llm-net"
fi

# Isolation: OpenClaw's network may just have been (re)created, the agent firewall must know it.
if systemctl is-active --quiet ai-lab-isolation.service 2>/dev/null; then
  sudo systemctl restart ai-lab-isolation.service && echo "→ Agent firewall reapplied (OpenClaw without Internet access)"
else
  echo "WARNING: OpenClaw has Internet access as long as isolation is not installed: lab isolation install (docs/agent-isolation.md)"
fi

echo
echo "Done. Control interface: http://127.0.0.1:18789/ (from your PC: through the SSH tunnel)"
echo "The gateway token is in $TARGET/.env (OPENCLAW_GATEWAY_TOKEN)."
echo "Check:  ss -tlnp | grep -E ':(18789|18790|3978)'  (must show 127.0.0.1)  and  lab isolation test"
