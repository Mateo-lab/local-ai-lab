#!/usr/bin/env bash
# ÉTAPE 4 (optionnelle) : démarre ComfyUI (génération d'images).
#
#     ./4-comfyui.sh          # démarre
#     ./4-comfyui.sh stop     # arrête (libère la VRAM)
#
# ComfyUI prend beaucoup de VRAM : il n'est PAS lancé par ./3-demarrer.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/comfyui"

docker info >/dev/null 2>&1 || { echo "Docker ne répond pas (voir ./1-prerequis.sh)." >&2; exit 1; }

if [ "${1:-}" = "stop" ]; then
  docker compose down
  echo "ComfyUI arrêté."
  exit 0
fi

docker network inspect ai-stack_ai-net >/dev/null 2>&1 || {
  echo "Le réseau de la stack n'existe pas : lance d'abord ./3-demarrer.sh" >&2; exit 1; }

mkdir -p data/models data/input data/output
# Les dossiers doivent appartenir à ton utilisateur (le conteneur tourne avec PUID/PGID)
printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" > .env

# Ollama garde son modèle en VRAM (OLLAMA_KEEP_ALIVE) : on le décharge pour laisser la place
echo "→ Déchargement des modèles Ollama (libère la VRAM)..."
for m in $(docker exec ollama ollama ps 2>/dev/null | awk 'NR>1 {print $1}'); do
  docker exec ollama ollama stop "$m" || true
done

docker compose up -d
cat <<'MSG'

ComfyUI : http://127.0.0.1:8188   (le premier démarrage peut prendre quelques minutes)

Il faut au moins UN modèle d'image. Dépose un fichier .safetensors dans :
    comfyui/data/models/checkpoints/
(ou utilise le gestionnaire de modèles de ComfyUI), puis redémarre : ./4-comfyui.sh

Ensuite, branchement dans Open WebUI : voir README, section « Images (ComfyUI) ».
MSG
