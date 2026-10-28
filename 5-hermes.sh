#!/usr/bin/env bash
# STEP 5 (optional): prepares and starts Hermes Agent.
#
#     ./5-hermes.sh MODEL           # prepares the config (1st time) then opens a conversation
#     ./5-hermes.sh MODEL doctor    # runs another Hermes subcommand (e.g. doctor)
#
# MODEL = EXACT name of the Ollama model, as shown by `docker exec ollama ollama list`.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/hermes"

MODEL="${1:-}"
[ -n "$MODEL" ] || { echo "Usage: ./5-hermes.sh MODEL_NAME   (see: docker exec ollama ollama list)" >&2; exit 1; }
shift || true

docker info >/dev/null 2>&1 || { echo "Docker does not answer (see ./1-prerequis.sh)." >&2; exit 1; }
docker network inspect hermes-net >/dev/null 2>&1 || {
  echo "The hermes-net network does not exist: update the stack then run ./3-demarrer.sh again" >&2; exit 1; }
if [ -n "$(docker ps -q -f 'name=^hermes-gw$')" ]; then
  echo "The Hermes Desktop gateway is running (lab gateway): it shares data/state.db with this session." >&2
  echo "Stop it first:  lab gateway stop" >&2; exit 1
fi

mkdir -p data/workspace
printf 'HERMES_UID=%s\nHERMES_GID=%s\n' "$(id -u)" "$(id -g)" > .env

if [ ! -f data/config.yaml ]; then
  sed -e "s|__MODEL__|${MODEL}|" -e "s|__MODELE__|${MODEL}|" config.yaml.example > data/config.yaml
  echo "→ data/config.yaml created (model: $MODEL)."
fi

CTX="$(docker exec ollama printenv OLLAMA_CONTEXT_LENGTH 2>/dev/null || echo '?')"
echo "→ Context served by Ollama: ${CTX} tokens (Hermes needs at least 64000)."

# Each session has a name, and it is stopped when this script ends, including when the terminal or the SSH connection
# closes (HUP signal). Without this, `docker compose run` leaves the container running forever (it waits for input
# that will never come): six orphan sessions, with network access, were found this way on the reference machine.
SESSION="hermes-session-$(date +%Y%m%d-%H%M%S)-$$"
fin_session() { docker rm -f "$SESSION" >/dev/null 2>&1 || true; }
trap fin_session EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# HERMES_WORKDIR (set by `lab dev start`): working folder INSIDE the container, e.g. /opt/data/workspace/projects/NAME
RUN=(docker compose run --rm --name "$SESSION")
[ -n "${HERMES_WORKDIR:-}" ] && RUN+=(-w "$HERMES_WORKDIR")
rc=0
if [ "$#" -gt 0 ]; then
  "${RUN[@]}" hermes "$@" || rc=$?
else
  "${RUN[@]}" hermes chat || rc=$?
fi
exit "$rc"
