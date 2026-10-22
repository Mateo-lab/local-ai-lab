#!/usr/bin/env bash
# ÉTAPE 7 (optionnelle) : banc d'essai scientifique (vitesse, cache KV, contexte, limite de puissance GPU).
#
#     ./7-bench.sh check                         # vérifie GPU, sudo, Docker
#     ./7-bench.sh list                          # expériences disponibles
#     ./7-bench.sh run quick-smoke --model qwen3.8:27b     # test rapide (~5 min)
#     ./7-bench.sh run power-sweep --model qwen3.8:27b     # courbe perte de perf / puissance
#     ./7-bench.sh run power-sweep --dry-run     # affiche le plan sans rien lancer
#     ./7-bench.sh report bench/results/<dossier>          # régénère le rapport
#
# Pendant un test, l'Ollama de production est arrêté (Open WebUI / Hermes n'ont plus de modèle) puis relancé.
# Ne rien lancer d'autre sur le GPU pendant ce temps. Méthodologie : bench/README.md
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/bench"

cmd="${1:-help}"; shift || true
case "$cmd" in help|-h|--help|"")
  sed -n '2,11p' ../7-bench.sh | sed 's/^# \{0,1\}//'; exit 0;; esac

# --- environnement Python isolé (créé une seule fois) ---
if [ ! -x .venv/bin/python ]; then
  python3 -c 'import venv, ensurepip' 2>/dev/null || {
    echo "Il manque le module venv : sudo apt install -y python3-venv   puis relance." >&2; exit 1; }
  echo "→ Création de l'environnement Python (une seule fois)..."
  python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt
fi
PY=.venv/bin/python

case "$cmd" in
  list|check|report) exec $PY -m labbench "$cmd" "$@" ;;
  run)
    docker info >/dev/null 2>&1 || { echo "Docker ne répond pas (voir ./1-prerequis.sh)." >&2; exit 1; }
    dry=0; ext=0
    for a in "$@"; do [ "$a" = "--dry-run" ] && dry=1; [ "$a" = "--url" ] && ext=1; done
    if [ $dry -eq 0 ]; then
      if [ $ext -eq 0 ]; then
        docker volume inspect ai-stack_ollama_data >/dev/null 2>&1 || {
          echo "Volume des modèles 'ai-stack_ollama_data' introuvable (ai-stack a-t-il déjà tourné ?)." >&2
          echo "Autre nom ? Ajoute --volume NOM (voir : docker volume ls)." >&2; exit 1; }
        echo "Ce test arrête l'Ollama de production pendant sa durée (relancé à la fin)."
        echo "Mets en pause : ComfyUI, Hermes, toute génération en cours."
      fi
      echo "Les droits administrateur sont nécessaires pour régler la limite de puissance du GPU."
      sudo -v
      read -r -p "Lancer ? [o/N] " ok; [ "$ok" = "o" ] || [ "$ok" = "O" ] || { echo "Annulé."; exit 0; }
    fi
    exec $PY -m labbench run "$@" ;;
  *) echo "Commande inconnue : $cmd (voir ./7-bench.sh help)" >&2; exit 1 ;;
esac
