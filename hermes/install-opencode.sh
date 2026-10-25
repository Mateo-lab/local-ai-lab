#!/usr/bin/env bash
# Installs OpenCode for Hermes in hermes/data/opencode (Hermes's volume, seen as /opt/data/opencode).
# The Hermes container has no Internet: the download is done here, in a throwaway copy of the Hermes image
# (same Node and same glibc as the ones that will run OpenCode), outside the isolated network.
# Usage: ./install-opencode.sh [VERSION] [MODEL]      (default: 1.19.4, qwen3.8:27b-64k)
# Does not overwrite an existing opencode.json. Can be run again.
set -euo pipefail
VERSION="${1:-1.19.4}"
MODEL="${2:-qwen3.8:27b-64k}"
cd "$(dirname "$0")"
D="$PWD/data/opencode"
IMG="$(docker compose config --images | head -n1)"
[ -n "$IMG" ] || { echo "Hermes image not found (docker compose config --images)" >&2; exit 1; }
mkdir -p "$D"

run() { docker run --rm --network bridge -u "$(id -u):$(id -g)" -e HOME=/tmp --entrypoint bash \
          -v "$PWD/data:/opt/data" "$IMG" -c "$1"; }

echo "→ Installing opencode-ai@$VERSION"
run "npm install --prefix /opt/data/opencode --no-audit --no-fund opencode-ai@$VERSION" || true
# npm 12 blocks install scripts; the opencode-ai postinstall puts the platform binary in place.
run "cd /opt/data/opencode/node_modules/opencode-ai && node postinstall.mjs"

if [ ! -f "$D/opencode.json" ]; then
  cat > "$D/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "model": "ollama/$MODEL",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": { "baseURL": "http://ollama:11434/v1" },
      "models": {
        "$MODEL": {
          "name": "$MODEL",
          "limit": { "context": 65536, "output": 8192 }
        }
      }
    }
  }
}
EOF
  echo "→ opencode.json created (model $MODEL, context 65536)"
else
  echo "→ opencode.json already exists, kept"
fi

cat > "$D/opencode" <<'EOF'
#!/bin/sh
# OpenCode wrapper for Hermes: config and data in /opt/data/opencode
D=/opt/data/opencode
export OPENCODE_CONFIG="$D/opencode.json"
export XDG_DATA_HOME="$D/xdg/data" XDG_CONFIG_HOME="$D/xdg/config" XDG_CACHE_HOME="$D/xdg/cache" XDG_STATE_HOME="$D/xdg/state"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"
exec "$D/node_modules/.bin/opencode" "$@"
EOF
chmod +x "$D/opencode"

echo -n "→ Installed version: "
run "/opt/data/opencode/opencode --version"
