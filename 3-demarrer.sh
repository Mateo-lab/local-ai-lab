#!/usr/bin/env bash
# ÉTAPE 3 : démarre la stack (Ollama, Open WebUI, n8n, Postgres, Qdrant) et le monitoring.
#
#     ./3-demarrer.sh                    # démarre tout
#     ./3-demarrer.sh NOM_DU_MODELE      # démarre tout ET télécharge ce modèle (plusieurs Go)
#     Sans argument : LAB_MODEL de lab.conf s'il existe, sinon aucun téléchargement.
#
# OpenClaw n'est PAS lancé ici : il s'installe à part, en dernier (voir README).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[ ! -f lab.conf ] || . ./lab.conf
MODEL="${1:-${LAB_MODEL:-}}"

command -v docker >/dev/null 2>&1 || { echo "Docker est introuvable : lance d'abord ./1-prerequis.sh" >&2; exit 1; }
if ! docker info >/dev/null 2>&1; then
  echo "Docker ne répond pas pour ton utilisateur." >&2
  echo "Si tu viens de l'installer, redémarre la machine (sudo reboot) puis relance ce script." >&2
  exit 1
fi
[ -f ai-stack/.env ] && [ -f monitoring/.env ] || { echo "Les fichiers .env manquent : lance d'abord ./2-secrets.sh" >&2; exit 1; }

echo "→ Test du GPU dans Docker..."
if ! docker run --rm --gpus all ubuntu nvidia-smi -L; then
  echo >&2
  echo "Docker ne voit pas la carte graphique. Relance ./1-prerequis.sh, puis redémarre la machine." >&2
  exit 1
fi

echo "→ Démarrage de la stack (le premier lancement télécharge plusieurs images)..."
(cd ai-stack && docker compose up -d)

echo "→ Démarrage du monitoring..."
(cd monitoring && docker compose up -d)

if [ -n "$MODEL" ]; then
  echo "→ Téléchargement du modèle $MODEL (patience)..."
  docker exec ollama ollama pull "$MODEL"
fi

echo
echo "=== État ==="
(cd ai-stack && docker compose ps)
(cd monitoring && docker compose ps)

cat <<'EOF'

Interfaces (accessibles UNIQUEMENT depuis cette machine) :
  Open WebUI : http://127.0.0.1:3000
  n8n        : http://127.0.0.1:5678
  Grafana    : http://127.0.0.1:3001   (utilisateur : admin)
  Prometheus : http://127.0.0.1:9090

Si tu travailles depuis un autre ordinateur, ouvre un tunnel SSH depuis ce dernier, par exemple :
  ssh -L 3000:127.0.0.1:3000 -L 5678:127.0.0.1:5678 -L 3001:127.0.0.1:3001 UTILISATEUR@IP-DE-LA-MACHINE
puis ouvre http://127.0.0.1:3000 dans ton navigateur.

Pas encore de modèle ? Télécharge-en un :
  docker exec -it ollama ollama pull NOM_DU_MODELE      (par ex. celui de lab.conf)
EOF
