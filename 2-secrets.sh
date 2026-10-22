#!/usr/bin/env bash
# ÉTAPE 2 : crée les fichiers ".env" avec des mots de passe générés au hasard.
#
#     ./2-secrets.sh
#
# Ce script ne demande rien : il génère les secrets pour toi.
# Il n'écrase jamais un .env existant.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

command -v openssl >/dev/null 2>&1 || { echo "Erreur : 'openssl' est introuvable (sudo apt install openssl)." >&2; exit 1; }

# make_env <dossier> <VARIABLE:octets> [<VARIABLE:octets> ...]
# Crée le .env s'il n'existe pas. S'il existe, ne touche à aucune valeur déjà remplie
# et complète seulement les variables manquantes ou vides (utile après une mise à jour).
make_env() {
  local dir="$1"; shift
  local spec var bytes value current added=0
  if [ ! -f "$dir/.env" ]; then
    cp "$dir/.env.example" "$dir/.env"
    echo "• $dir/.env créé."
  fi
  for spec in "$@"; do
    var="${spec%%:*}"; bytes="${spec##*:}"
    current="$(grep -E "^${var}=" "$dir/.env" | head -n1 | cut -d= -f2- || true)"
    [ -n "$current" ] && continue
    value="$(openssl rand -hex "$bytes")"
    if grep -qE "^${var}=" "$dir/.env"; then
      sed -i "s|^${var}=.*|${var}=${value}|" "$dir/.env"
    else
      printf '%s=%s\n' "$var" "$value" >> "$dir/.env"
    fi
    added=1
    echo "• $dir/.env : $var généré."
  done
  [ "$added" -eq 0 ] && echo "• $dir/.env : rien à compléter, je n'y touche pas."
  chmod 600 "$dir/.env"
}

make_env ai-stack   WEBUI_SECRET_KEY:32 N8N_ENCRYPTION_KEY:32 POSTGRES_N8N_PASSWORD:24 SEARXNG_SECRET:32
make_env monitoring GRAFANA_ADMIN_PASSWORD:16

echo
echo "Où sont les secrets ?"
echo "  $(pwd)/ai-stack/.env      (fichier caché : 'ls -a ai-stack' pour le voir)"
echo "  $(pwd)/monitoring/.env"
echo
echo "À retenir :"
echo "  • Mot de passe de Grafana (utilisateur 'admin') :"
echo "        grep GRAFANA_ADMIN_PASSWORD monitoring/.env"
echo "  • SAUVEGARDE ai-stack/.env quelque part : sans N8N_ENCRYPTION_KEY, les identifiants"
echo "    enregistrés dans n8n deviennent illisibles si tu recrées la machine."
echo
echo "Étape suivante :   ./3-demarrer.sh"
