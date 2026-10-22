#!/usr/bin/env bash
# ÉTAPE 5 (optionnelle) : prépare et lance Hermes Agent.
#
#     ./5-hermes.sh MODELE          # prépare la config (1re fois) puis ouvre une discussion
#     ./5-hermes.sh MODELE doctor   # lance un autre sous-commande de Hermes (ex. doctor)
#
# MODELE = nom EXACT du modèle Ollama, tel qu'affiché par `docker exec ollama ollama list`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/hermes"

MODEL="${1:-}"
[ -n "$MODEL" ] || { echo "Usage : ./5-hermes.sh NOM_DU_MODELE   (voir : docker exec ollama ollama list)" >&2; exit 1; }
shift || true

docker info >/dev/null 2>&1 || { echo "Docker ne répond pas (voir ./1-prerequis.sh)." >&2; exit 1; }
docker network inspect hermes-net >/dev/null 2>&1 || {
  echo "Le réseau hermes-net n'existe pas : mets à jour la stack puis relance ./3-demarrer.sh" >&2; exit 1; }

mkdir -p data/workspace
printf 'HERMES_UID=%s\nHERMES_GID=%s\n' "$(id -u)" "$(id -g)" > .env

if [ ! -f data/config.yaml ]; then
  sed "s|__MODELE__|${MODEL}|" config.yaml.example > data/config.yaml
  echo "→ data/config.yaml créé (modèle : $MODEL)."
fi

CTX="$(docker exec ollama printenv OLLAMA_CONTEXT_LENGTH 2>/dev/null || echo '?')"
echo "→ Contexte servi par Ollama : ${CTX} tokens (Hermes demande au moins 64000)."

# HERMES_WORKDIR (posé par `lab dev start`) : dossier de travail DANS le conteneur, ex. /opt/data/workspace/projects/NOM
RUN=(docker compose run --rm)
[ -n "${HERMES_WORKDIR:-}" ] && RUN+=(-w "$HERMES_WORKDIR")
if [ "$#" -gt 0 ]; then
  "${RUN[@]}" hermes "$@"
else
  "${RUN[@]}" hermes chat
fi
