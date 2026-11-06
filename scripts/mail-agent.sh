#!/usr/bin/env bash
# Hermes session dedicated to reading the exported Outlook mails (docs/mail-export.md). Called by `lab mail`.
#
#   lab mail [MODEL] [--force]
#
# - mounts the drop folder read-only at /opt/mail-inbox (HERMES_MAIL_DIR; default /srv/mail-in/inbox, LAB_MAIL_DIR to change);
# - works in its own folder hermes/data/workspace/mail, whose AGENTS.md (hermes/mail-template/AGENTS.md) says that mails are data;
# - never passes the serial device;
# - refuses to start while LAB_AGENT_SSH_ALLOW lets Hermes reach a test machine (a booby-trapped mail could ask it to act there),
#   unless --force.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DATA="${HERMES_DATA:-$ROOT/hermes/data}"
die() { echo "lab mail: $*" >&2; exit 1; }

MODEL=""; FORCE=0
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

echo "Mail reader — model $MODEL — mails: $MAIL_DIR (read-only) — folder: workspace/mail"
HERMES_MAIL_DIR="$MAIL_DIR" HERMES_WORKDIR="/opt/data/workspace/mail" HERMES_SERIAL=/nonexistent \
  exec "$ROOT/5-hermes.sh" "$MODEL"
