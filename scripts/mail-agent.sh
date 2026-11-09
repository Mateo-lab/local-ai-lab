#!/usr/bin/env bash
# Hermes session dedicated to reading the exported Outlook mails (docs/mail-export.md). Called by `lab mail`.
#
#   lab mail [MODEL] [--force]            interactive session
#   lab mail run registre|planning|synchro [MODEL] [--force]   one pass without conversation (hermes chat -q), then exits
#
# - mounts the drop folder read-only at /opt/mail-inbox (HERMES_MAIL_DIR; default /srv/mail-in/inbox, LAB_MAIL_DIR to change);
# - works in its own folder hermes/data/workspace/mail, whose AGENTS.md (hermes/mail-template/AGENTS.md) says that mails are data;
# - never passes the serial device;
# - runs with agent.reasoning_effort = LAB_MAIL_REASONING (default low; "off" leaves it alone) ONLY for this session: the
#   previous state of config.yaml is put back when the session ends (and at the next start if a kill prevented it);
# - refuses to start while LAB_AGENT_SSH_ALLOW lets Hermes reach a test machine (a booby-trapped mail could ask it to act there),
#   unless --force.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DATA="${HERMES_DATA:-$ROOT/hermes/data}"
die() { echo "lab mail: $*" >&2; exit 1; }

MODEL=""; FORCE=0; QUERY=""
if [ "${1:-}" = run ]; then   # fixed prompts only (nothing typed by the caller reaches the agent): the phrases AGENTS.md answers to
  case "${2:-}" in
    registre) QUERY="Mets à jour le registre." ;;
    planning) QUERY="Prépare le sprint planning." ;;
    synchro)  QUERY="Prépare la synchro." ;;
    *) die "usage: lab mail run registre|planning|synchro [MODEL] [--force]" ;;
  esac
  shift 2
fi
for a in "$@"; do case "$a" in --force) FORCE=1 ;; -*) die "unknown option $a" ;; *) [ -z "$MODEL" ] && MODEL="$a" || die "too many arguments" ;; esac; done

MAIL_DIR="${LAB_MAIL_DIR:-/srv/mail-in/inbox}"
[ -d "$MAIL_DIR" ] || die "$MAIL_DIR is not a folder (is the export set up? docs/mail-export.md)"
if [ -n "${LAB_AGENT_SSH_ALLOW:-}" ] && [ "$FORCE" != 1 ]; then
  die "LAB_AGENT_SSH_ALLOW is set (\"$LAB_AGENT_SSH_ALLOW\"): while Hermes reads mails, a booby-trapped mail could ask it to act on that machine. Empty it in lab.conf then 'lab isolation apply', or add --force."
fi

[ -n "$MODEL" ] || MODEL="$("$ROOT/lab" main-model)"
[ -n "$MODEL" ] || die "model not found: lab mail MODEL_NAME (models: lab models)"
docker exec ollama ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$MODEL" || die "model \"$MODEL\" not found in Ollama (lab models)"

W="$DATA/workspace/mail"
mkdir -p "$W"
[ -f "$W/AGENTS.md" ] || cp "$ROOT/hermes/mail-template/AGENTS.md" "$W/AGENTS.md"

cfg="$DATA/config.yaml"
if [ -f "$cfg" ]; then
  cur="$(awk '/^  default:/{print $2; exit}' "$cfg")"
  if [ "$cur" != "$MODEL" ]; then
    cp "$cfg" "$cfg.avant-modele"; sed -i "s|^  default:.*|  default: $MODEL|" "$cfg"
    echo "→ Hermes model: ${cur:-?} → $MODEL (copy: config.yaml.avant-modele)"
  fi
fi

# --- reasoning level, for this session only -------------------------------------------------------------------------------
# config.yaml is shared by every Hermes session, so the change is undone when this session ends. What was changed is recorded
# in $STATE ("kind|previous value or size|value we set"), so a leftover (kill -9, power cut) is repaired at the next start.
EFFORT="${LAB_MAIL_REASONING:-low}"
[[ "$EFFORT" =~ ^(xhigh|high|medium|low|minimal|none|off)$ ]] || die "LAB_MAIL_REASONING=\"$EFFORT\": expected xhigh|high|medium|low|minimal|none|off"
STATE="$DATA/.mail-reasoning-undo"

undo_reasoning() { # puts config.yaml back as it was before set_reasoning
  [ -f "$STATE" ] || return 0
  local kind prev set blk
  IFS='|' read -r kind prev set < "$STATE"
  if [ -f "$cfg" ]; then
    case "$kind" in
      replace) sed -i "/^agent:/,/^[^ #]/ s/^  reasoning_effort: ${set}\$/  reasoning_effort: ${prev}/" "$cfg" ;;
      insert)  sed -i "/^agent:/{n;/^  reasoning_effort: ${set}\$/d}" "$cfg" ;;
      append)  # prev = size of the file before we appended; cut back only if the tail is still exactly our block
               blk=$'\nagent:\n  reasoning_effort: '"$set"$'\n'
               [ "$(tail -c "${#blk}" "$cfg"; echo x)" = "${blk}x" ] && truncate -s "$prev" "$cfg" ;;
    esac
  fi
  rm -f "$STATE"
}

set_reasoning() { # set_reasoning VALUE
  local v="$1" kind prev="" shown=""
  [ -f "$cfg" ] || return 0
  if ! grep -q '^agent:' "$cfg"; then
    kind=append; prev="$(stat -c %s "$cfg")"; printf '\nagent:\n  reasoning_effort: %s\n' "$v" >> "$cfg"
  elif prev="$(awk '/^agent:/{a=1;next} a&&/^[^ #]/{exit} a&&/^  reasoning_effort:/{print $2; f=1; exit} END{exit !f}' "$cfg")"; then
    kind=replace; shown="$prev"
    sed -i "/^agent:/,/^[^ #]/ s/^  reasoning_effort:.*/  reasoning_effort: ${v}/" "$cfg"
  else
    kind=insert; prev=""
    sed -i "/^agent:/a\\  reasoning_effort: ${v}" "$cfg"
  fi
  printf '%s|%s|%s\n' "$kind" "$prev" "$v" > "$STATE"
  echo "→ Reasoning: ${shown:-default} → $v for this session only (put back when it ends)."
}

undo_reasoning                          # repairs a leftover of a session that could not clean up
if [ "$EFFORT" != off ] && [ -f "$cfg" ]; then
  trap undo_reasoning EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  set_reasoning "$EFFORT"
fi

echo "Mail reader — model $MODEL — mails: $MAIL_DIR (read-only) — folder: workspace/mail"
HERMES_MAIL_DIR="$MAIL_DIR" HERMES_WORKDIR="/opt/data/workspace/mail" HERMES_SERIAL=/nonexistent \
  "$ROOT/5-hermes.sh" "$MODEL" ${QUERY:+chat -q "$QUERY"}
exit $?
