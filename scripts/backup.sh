#!/usr/bin/env bash
# Encrypted backups (restic) of what cannot be found again on the Internet:
#   PostgreSQL databases (n8n, Langfuse), Open WebUI / n8n / Qdrant volumes, .env files, Hermes data, benchmark results.
# NOT backed up (can be downloaded again): Ollama models, Docker images, ComfyUI cache.
#
#   scripts/backup.sh init        creates the encrypted repository + the password (once)
#   scripts/backup.sh run         makes a backup
#   scripts/backup.sh list        lists the backups
#   scripts/backup.sh check       checks the repository's integrity
#   scripts/backup.sh restore ID TARGET   restores snapshot ID into the TARGET folder (never in place)
#   scripts/backup.sh schedule    installs a daily backup at 03:30 (systemd timer, asks for sudo); `schedule off` removes it
#   scripts/backup.sh last        age of the last backup (used by `lab doctor`)
#   scripts/backup.sh repo        prints the repository's location (used by the off-machine copy from Windows)
#
# Variables: BACKUP_REPO (default $LAB_DATA_DIR/backups/restic, i.e. /data/backups/restic), BACKUP_PASSWORD_FILE (default ~/.config/aibeast-backup/password)
# Repository on the SAME disk as the data: protects against a handling mistake, NOT against losing the disk.
# For real protection, point BACKUP_REPO to another disk or a server (see docs/backups.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/lab.conf" ]; then . "$ROOT/lab.conf"; fi
LAB_DATA_DIR="${LAB_DATA_DIR:-/data}"
export RESTIC_REPOSITORY="${BACKUP_REPO:-$LAB_DATA_DIR/backups/restic}"
export RESTIC_PASSWORD_FILE="${BACKUP_PASSWORD_FILE:-$HOME/.config/aibeast-backup/password}"
STAGE="${BACKUP_STAGE:-$LAB_DATA_DIR/backups/staging}"
KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)

need() { command -v "$1" >/dev/null 2>&1 || { echo "'$1' is missing (sudo apt install $1)." >&2; exit 1; }; }
need restic; need docker

cid() { # cid PROJECT SERVICE -> container id (through compose labels, independent of names)
  docker ps -q --filter "label=com.docker.compose.project=$1" --filter "label=com.docker.compose.service=$2" | head -n1
}

cid_in() { # cid_in SUBFOLDER SERVICE -> id of the container whose compose file lives in ROOT/SUBFOLDER
  # (Langfuse is cloned into langfuse/app: Docker then names the project "app", not "langfuse")
  local id wd
  for id in $(docker ps -q --filter "label=com.docker.compose.service=$2"); do
    wd="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$id" 2>/dev/null || true)"
    [ "$wd" = "$ROOT/$1" ] && { echo "$id"; return; }
  done
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init)
    if [ -f "$RESTIC_PASSWORD_FILE" ]; then echo "Password already present: $RESTIC_PASSWORD_FILE"
    else
      mkdir -p "$(dirname "$RESTIC_PASSWORD_FILE")"; umask 077
      openssl rand -base64 33 > "$RESTIC_PASSWORD_FILE"
      echo "Password generated: $RESTIC_PASSWORD_FILE"
      echo "!! COPY IT NOW into a password manager, off the AI machine. Without it, the backups are unreadable."
    fi
    mkdir -p "$RESTIC_REPOSITORY" "$STAGE"
    restic cat config >/dev/null 2>&1 && echo "Repository already initialised: $RESTIC_REPOSITORY" || restic init
    ;;

  run)
    mkdir -p "$STAGE"; rm -rf "${STAGE:?}"/*
    ok=1

    # 1. PostgreSQL databases: pg_dump (consistent, unlike a copy of files during writes)
    c="$(cid ai-stack postgres-n8n)"
    if [ -n "$c" ]; then
      docker exec "$c" pg_dump -U n8n -d n8n --clean --if-exists > "$STAGE/n8n.sql" && echo "✓ n8n database" || { echo "✗ pg_dump n8n"; ok=0; }
    else echo "· postgres-n8n stopped: skipped"; fi
    c="$(cid_in langfuse/app postgres)"
    if [ -n "$c" ]; then
      docker exec "$c" pg_dumpall -U postgres > "$STAGE/langfuse.sql" && echo "✓ Langfuse database" || { echo "✗ pg_dumpall Langfuse"; ok=0; }
    else echo "· Langfuse stopped or missing: skipped"; fi

    # 2. Volumes (files): Open WebUI (accounts, conversations, documents), n8n (key, credentials), Qdrant (vectors)
    for v in ai-stack_open_webui_data ai-stack_n8n_data ai-stack_qdrant_data; do
      if docker volume inspect "$v" >/dev/null 2>&1; then
        docker run --rm -v "$v":/src:ro -v "$STAGE":/out alpine tar -C /src -cf "/out/$v.tar" . \
          && echo "✓ volume $v" || { echo "✗ volume $v"; ok=0; }
      else echo "· volume $v missing: skipped"; fi
    done

    # 3. Configuration files and secrets (encrypted by restic)
    paths=("$STAGE")
    for f in ai-stack/.env alerting/.env monitoring/.env langfuse/app/.env hermes/.env hermes/data openclaw/.env bench/results; do
      [ -e "$ROOT/$f" ] && paths+=("$ROOT/$f")
    done

    restic backup --tag aibeast --host aibeast "${paths[@]}"
    restic forget --tag aibeast "${KEEP[@]}" --prune
    rm -rf "${STAGE:?}"/*
    [ "$ok" = 1 ] && echo "Backup finished." || { echo "Backup finished WITH errors (see ✗ above)." >&2; exit 2; }
    ;;

  repo)  echo "$RESTIC_REPOSITORY" ;;
  list)  restic snapshots --tag aibeast ;;
  check) restic check ;;

  restore)
    id="${1:?usage: restore ID TARGET}"; target="${2:?usage: restore ID TARGET}"
    [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ] && { echo "The target must be empty or missing: $target" >&2; exit 1; }
    restic restore "$id" --target "$target"
    echo "Restored into $target. Nothing was replaced: see docs/backups.md to put the data back in place."
    ;;

  last)
    t="$(restic snapshots --tag aibeast --latest 1 --json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[-1]["time"] if d else "")' 2>/dev/null || true)"
    [ -z "$t" ] && { echo "none"; exit 1; }
    python3 - "$t" <<'PY'
import sys,datetime as d
t=d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00"))
h=(d.datetime.now(d.timezone.utc)-t).total_seconds()/3600
print(f"{h:.0f} h ago" if h<48 else f"{h/24:.0f} days ago")
sys.exit(0 if h<48 else 1)
PY
    ;;

  schedule)
    if [ "${1:-on}" = off ]; then
      sudo systemctl disable --now aibeast-backup.timer 2>/dev/null || true
      sudo rm -f /etc/systemd/system/aibeast-backup.service /etc/systemd/system/aibeast-backup.timer
      sudo systemctl daemon-reload; echo "Scheduled backup removed."; exit 0
    fi
    [ -f "$RESTIC_PASSWORD_FILE" ] || { echo "Run this first: scripts/backup.sh init" >&2; exit 1; }
    sudo tee /etc/systemd/system/aibeast-backup.service >/dev/null <<UNIT
[Unit]
Description=AiBeast encrypted backup
RequiresMountsFor=$LAB_DATA_DIR
After=docker.service

[Service]
Type=oneshot
User=$(id -un)
Environment=BACKUP_REPO=$RESTIC_REPOSITORY
Environment=BACKUP_PASSWORD_FILE=$RESTIC_PASSWORD_FILE
ExecStart=$ROOT/scripts/backup.sh run
UNIT
    sudo tee /etc/systemd/system/aibeast-backup.timer >/dev/null <<'UNIT'
[Unit]
Description=AiBeast daily backup

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    sudo systemctl daemon-reload && sudo systemctl enable --now aibeast-backup.timer
    systemctl list-timers aibeast-backup.timer --no-pager
    ;;

  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
