#!/usr/bin/env bash
# Génère la configuration SSH du poste client (Windows, macOS ou Linux) à partir de lab.conf.
#
#   lab client            écrit windows/ssh_config_aibeast.txt et affiche la marche à suivre
#   lab client --print    affiche seulement le bloc de configuration (rien n'est écrit)
#
# Le bloc définit le raccourci « aibeast » (utilisé par tous les scripts de windows/) et les tunnels
# vers toutes les interfaces, plus le bureau à distance (RDP). Rien n'est ouvert sur le réseau :
# les interfaces restent liées à 127.0.0.1 sur la machine IA, les tunnels passent par SSH.
# Voir docs/acces-distant.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
if [ -f "$ROOT/lab.conf" ]; then . "$ROOT/lab.conf"; fi

HOST="${LAB_HOST:-}"
USER_="${LAB_USER:-${USER:-$(id -un)}}"
PORT="${LAB_SSH_PORT:-22}"
KEY="${LAB_SSH_KEY:-~/.ssh/id_ed25519}"
RDP="${LAB_RDP_LOCAL_PORT:-13389}"

if [ -z "$HOST" ]; then
  cat >&2 <<EOF
lab client : LAB_HOST n'est pas défini.
  1. cp lab.conf.example lab.conf   (si ce n'est pas déjà fait)
  2. dans lab.conf, mets l'adresse par laquelle ton PC joint cette machine, par exemple :
       LAB_HOST=192.168.1.50
     Adresses de cette machine :
$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sed 's/^/       /')
  3. relance : lab client
EOF
  exit 1
fi
case "$HOST$USER_$PORT$KEY$RDP" in *[[:space:]\"\'\;\&\|\`\$]*) echo "lab client : valeur invalide dans lab.conf (espace ou caractère spécial)" >&2; exit 1 ;; esac
[[ "$PORT" =~ ^[0-9]+$ && "$RDP" =~ ^[0-9]+$ ]] || { echo "lab client : LAB_SSH_PORT et LAB_RDP_LOCAL_PORT doivent être des nombres" >&2; exit 1; }

bloc() {
cat <<EOF
# Raccourci SSH vers la machine IA (généré par « lab client » le $(date +%Y-%m-%d)).
# À AJOUTER à la fin de ton fichier de configuration SSH :
#   Windows : %USERPROFILE%\\.ssh\\config      macOS / Linux : ~/.ssh/config
# Le créer s'il n'existe pas. Puis : ssh aibeast
Host aibeast
  HostName $HOST
  Port $PORT
  User $USER_
  IdentityFile $KEY
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ExitOnForwardFailure yes
  # Tunnels joignables depuis CE PC seulement (jamais depuis son réseau), même si GatewayPorts est activé ailleurs
  GatewayPorts no
  # Portail (page d'accueil) et panneau de boutons
  LocalForward 127.0.0.1:3010 127.0.0.1:3010
  LocalForward 127.0.0.1:3011 127.0.0.1:3011
  # Interfaces : Open WebUI, n8n, Qdrant, ComfyUI
  LocalForward 127.0.0.1:3000 127.0.0.1:3000
  LocalForward 127.0.0.1:5678 127.0.0.1:5678
  LocalForward 127.0.0.1:6333 127.0.0.1:6333
  LocalForward 127.0.0.1:8188 127.0.0.1:8188
  # Observabilité : Grafana, Prometheus, Langfuse
  LocalForward 127.0.0.1:3001 127.0.0.1:3001
  LocalForward 127.0.0.1:9090 127.0.0.1:9090
  LocalForward 127.0.0.1:3002 127.0.0.1:3002
  # Notifications (ntfy), Alertmanager, OpenClaw
  LocalForward 127.0.0.1:2586 127.0.0.1:2586
  LocalForward 127.0.0.1:9093 127.0.0.1:9093
  LocalForward 127.0.0.1:18789 127.0.0.1:18789
  # Bureau à distance (RDP) : sur ton PC, connecte-toi à 127.0.0.1:$RDP
  LocalForward 127.0.0.1:$RDP 127.0.0.1:3389
EOF
}

if [ "${1:-}" = "--print" ]; then bloc; exit 0; fi

OUT="$ROOT/windows/ssh_config_aibeast.txt"
bloc | sed 's/$/\r/' > "$OUT"     # fins de ligne Windows : le fichier s'ouvre proprement dans le Bloc-notes
echo "Écrit : $OUT  (ignoré par git : il contient ton adresse)"
echo
bloc
cat <<EOF

─── Marche à suivre sur ton PC (détail : docs/acces-distant.md) ───────────────────
1. Créer une clé, si tu n'en as pas :        ssh-keygen -t ed25519
2. Copier la clé PUBLIQUE sur cette machine (mot de passe du compte demandé une dernière fois) :
   Windows (PowerShell) :
     type \$env:USERPROFILE\\.ssh\\id_ed25519.pub | ssh -p $PORT $USER_@$HOST "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
   macOS / Linux :
     ssh-copy-id -p $PORT $USER_@$HOST
3. Ajouter le bloc ci-dessus à la fin du fichier de configuration SSH du PC.
4. Tester :  ssh aibeast  → doit se connecter SANS demander le mot de passe du compte.
5. Ouvrir les tunnels :  ssh -N aibeast  (ou windows\\outils\\Ouvrir-AiBeast.bat), puis http://127.0.0.1:3010
EOF
