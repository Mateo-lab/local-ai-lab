#!/usr/bin/env bash
# Sauvegardes chiffrées (restic) de ce qui ne se retrouve pas sur Internet :
#   bases PostgreSQL (n8n, Langfuse), volumes Open WebUI / n8n / Qdrant, fichiers .env, données Hermes, résultats du banc.
# NON sauvegardé (se retélécharge) : modèles Ollama, images Docker, cache ComfyUI.
#
#   scripts/backup.sh init        crée le dépôt chiffré + le mot de passe (une seule fois)
#   scripts/backup.sh run         fait une sauvegarde
#   scripts/backup.sh list        liste les sauvegardes
#   scripts/backup.sh check       vérifie l'intégrité du dépôt
#   scripts/backup.sh restore ID CIBLE   restaure l'instantané ID dans le dossier CIBLE (jamais en place)
#   scripts/backup.sh schedule    installe une sauvegarde quotidienne à 03:30 (timer systemd, demande sudo) ; `schedule off` la retire
#   scripts/backup.sh last        âge de la dernière sauvegarde (utilisé par `lab doctor`)
#   scripts/backup.sh repo        affiche l'emplacement du dépôt (utilisé par la copie hors machine depuis Windows)
#
# Variables : BACKUP_REPO (défaut $LAB_DATA_DIR/backups/restic, soit /data/backups/restic), BACKUP_PASSWORD_FILE (défaut ~/.config/aibeast-backup/password)
# Dépôt sur le MÊME disque que les données : protège d'une erreur de manipulation, PAS de la perte du disque.
# Pour une vraie protection, pointe BACKUP_REPO vers un autre disque ou un serveur (voir docs/backups.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/lab.conf" ]; then . "$ROOT/lab.conf"; fi
LAB_DATA_DIR="${LAB_DATA_DIR:-/data}"
export RESTIC_REPOSITORY="${BACKUP_REPO:-$LAB_DATA_DIR/backups/restic}"
export RESTIC_PASSWORD_FILE="${BACKUP_PASSWORD_FILE:-$HOME/.config/aibeast-backup/password}"
STAGE="${BACKUP_STAGE:-$LAB_DATA_DIR/backups/staging}"
KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)

need() { command -v "$1" >/dev/null 2>&1 || { echo "Il manque '$1' (sudo apt install $1)." >&2; exit 1; }; }
need restic; need docker

cid() { # cid PROJET SERVICE -> id du conteneur (par étiquettes compose, indépendant des noms)
  docker ps -q --filter "label=com.docker.compose.project=$1" --filter "label=com.docker.compose.service=$2" | head -n1
}

cid_in() { # cid_in SOUS-DOSSIER SERVICE -> id du conteneur dont le compose vit dans ROOT/SOUS-DOSSIER
  # (Langfuse est cloné dans langfuse/app : Docker nomme alors le projet « app », pas « langfuse »)
  local id wd
  for id in $(docker ps -q --filter "label=com.docker.compose.service=$2"); do
    wd="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$id" 2>/dev/null || true)"
    [ "$wd" = "$ROOT/$1" ] && { echo "$id"; return; }
  done
}

cmd="${1:-}"; shift || true
case "$cmd" in
  init)
    if [ -f "$RESTIC_PASSWORD_FILE" ]; then echo "Mot de passe déjà présent : $RESTIC_PASSWORD_FILE"
    else
      mkdir -p "$(dirname "$RESTIC_PASSWORD_FILE")"; umask 077
      openssl rand -base64 33 > "$RESTIC_PASSWORD_FILE"
      echo "Mot de passe généré : $RESTIC_PASSWORD_FILE"
      echo "!! COPIE-LE MAINTENANT dans un gestionnaire de mots de passe, hors d'AiBeast. Sans lui, les sauvegardes sont illisibles."
    fi
    mkdir -p "$RESTIC_REPOSITORY" "$STAGE"
    restic cat config >/dev/null 2>&1 && echo "Dépôt déjà initialisé : $RESTIC_REPOSITORY" || restic init
    ;;

  run)
    mkdir -p "$STAGE"; rm -rf "${STAGE:?}"/*
    ok=1

    # 1. Bases PostgreSQL : pg_dump (cohérent, contrairement à une copie de fichiers pendant l'écriture)
    c="$(cid ai-stack postgres-n8n)"
    if [ -n "$c" ]; then
      docker exec "$c" pg_dump -U n8n -d n8n --clean --if-exists > "$STAGE/n8n.sql" && echo "✓ base n8n" || { echo "✗ pg_dump n8n"; ok=0; }
    else echo "· postgres-n8n arrêté : ignoré"; fi
    c="$(cid_in langfuse/app postgres)"
    if [ -n "$c" ]; then
      docker exec "$c" pg_dumpall -U postgres > "$STAGE/langfuse.sql" && echo "✓ base Langfuse" || { echo "✗ pg_dumpall Langfuse"; ok=0; }
    else echo "· Langfuse arrêté ou absent : ignoré"; fi

    # 2. Volumes (fichiers) : Open WebUI (comptes, conversations, documents), n8n (clé, identifiants), Qdrant (vecteurs)
    for v in ai-stack_open_webui_data ai-stack_n8n_data ai-stack_qdrant_data; do
      if docker volume inspect "$v" >/dev/null 2>&1; then
        docker run --rm -v "$v":/src:ro -v "$STAGE":/out alpine tar -C /src -cf "/out/$v.tar" . \
          && echo "✓ volume $v" || { echo "✗ volume $v"; ok=0; }
      else echo "· volume $v absent : ignoré"; fi
    done

    # 3. Fichiers de configuration et secrets (chiffrés par restic)
    paths=("$STAGE")
    for f in ai-stack/.env alerting/.env monitoring/.env langfuse/app/.env hermes/.env hermes/data openclaw/.env bench/results; do
      [ -e "$ROOT/$f" ] && paths+=("$ROOT/$f")
    done

    restic backup --tag aibeast --host aibeast "${paths[@]}"
    restic forget --tag aibeast "${KEEP[@]}" --prune
    rm -rf "${STAGE:?}"/*
    [ "$ok" = 1 ] && echo "Sauvegarde terminée." || { echo "Sauvegarde terminée AVEC des erreurs (voir ✗ ci-dessus)." >&2; exit 2; }
    ;;

  repo)  echo "$RESTIC_REPOSITORY" ;;
  list)  restic snapshots --tag aibeast ;;
  check) restic check ;;

  restore)
    id="${1:?usage : restore ID CIBLE}"; target="${2:?usage : restore ID CIBLE}"
    [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ] && { echo "La cible doit être vide ou absente : $target" >&2; exit 1; }
    restic restore "$id" --target "$target"
    echo "Restauré dans $target. Rien n'a été remplacé : voir docs/backups.md pour remettre les données en place."
    ;;

  last)
    t="$(restic snapshots --tag aibeast --latest 1 --json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[-1]["time"] if d else "")' 2>/dev/null || true)"
    [ -z "$t" ] && { echo "aucune"; exit 1; }
    python3 - "$t" <<'PY'
import sys,datetime as d
t=d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00"))
h=(d.datetime.now(d.timezone.utc)-t).total_seconds()/3600
print(f"il y a {h:.0f} h" if h<48 else f"il y a {h/24:.0f} jours")
sys.exit(0 if h<48 else 1)
PY
    ;;

  schedule)
    if [ "${1:-on}" = off ]; then
      sudo systemctl disable --now aibeast-backup.timer 2>/dev/null || true
      sudo rm -f /etc/systemd/system/aibeast-backup.service /etc/systemd/system/aibeast-backup.timer
      sudo systemctl daemon-reload; echo "Sauvegarde planifiée retirée."; exit 0
    fi
    [ -f "$RESTIC_PASSWORD_FILE" ] || { echo "Lance d'abord : scripts/backup.sh init" >&2; exit 1; }
    sudo tee /etc/systemd/system/aibeast-backup.service >/dev/null <<UNIT
[Unit]
Description=Sauvegarde chiffrée AiBeast
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
Description=Sauvegarde quotidienne AiBeast

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
