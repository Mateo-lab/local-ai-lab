#!/usr/bin/env bash
# Installe OpenClaw en Docker (image officielle pré-construite) et le branche
# sur l'Ollama de ../ai-stack via le réseau Docker `llm-net`.
#
# Usage :  ./install.sh
# Variables optionnelles :
#   OPENCLAW_DIR    dossier d'installation (défaut : ~/openclaw)
#   OPENCLAW_IMAGE  image à utiliser       (défaut : ghcr.io/openclaw/openclaw:latest)
#                   Pour la fonction navigateur de la gateway : ...:latest-browser
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${OPENCLAW_DIR:-$HOME/openclaw}"
export OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Erreur : '$1' est introuvable." >&2; exit 1; }; }
need docker
need git
docker compose version >/dev/null 2>&1 || { echo "Erreur : Docker Compose v2 est requis." >&2; exit 1; }

# Le réseau llm-net est créé quand la stack ai-stack démarre
if ! docker network inspect llm-net >/dev/null 2>&1; then
  echo "Erreur : le réseau Docker 'llm-net' n'existe pas." >&2
  echo "Démarre d'abord la stack :  cd ../ai-stack && docker compose up -d" >&2
  exit 1
fi

if [ -d "$TARGET/.git" ]; then
  echo "→ Dépôt OpenClaw déjà présent, mise à jour : $TARGET"
  git -C "$TARGET" pull --ff-only
else
  echo "→ Clonage du dépôt OpenClaw dans $TARGET"
  git clone https://github.com/openclaw/openclaw.git "$TARGET"
fi

echo "→ Ajout de l'override réseau (llm-net)"
cp "$HERE/docker-compose.override.yml" "$TARGET/docker-compose.override.yml"

cd "$TARGET"
echo "→ Image : $OPENCLAW_IMAGE"
echo
echo "L'assistant d'installation va démarrer. Réponses à donner :"
echo "  • Provider : Ollama, mode « Local only »"
echo "  • URL Ollama : http://ollama:11434   (PAS host.docker.internal)"
echo "  • Modèle : celui que tu as téléchargé (ex. qwen3.5:27b)"
echo
./scripts/docker/setup.sh

echo
echo "Terminé. Interface de contrôle : http://127.0.0.1:18789/"
echo "Le jeton de la gateway est dans $TARGET/.env (OPENCLAW_GATEWAY_TOKEN)."
echo "Vérification de l'exposition réseau :  ss -tlnp | grep 18789"
