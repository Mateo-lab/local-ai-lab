#!/usr/bin/env bash
# STEP 2: creates the ".env" files with randomly generated passwords.
#
#     ./2-secrets.sh
#
# This script asks nothing: it generates the secrets for you.
# It never overwrites an existing .env.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

command -v openssl >/dev/null 2>&1 || { echo "Error: 'openssl' not found (sudo apt install openssl)." >&2; exit 1; }

# make_env <folder> <VARIABLE:bytes> [<VARIABLE:bytes> ...]
# Creates the .env if it does not exist. If it exists, touches no value already filled in
# and only fills in missing or empty variables (useful after an update).
make_env() {
  local dir="$1"; shift
  local spec var bytes value current added=0
  if [ ! -f "$dir/.env" ]; then
    cp "$dir/.env.example" "$dir/.env"
    echo "• $dir/.env created."
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
    echo "• $dir/.env: $var generated."
  done
  [ "$added" -eq 0 ] && echo "• $dir/.env: nothing to fill in, left untouched."
  chmod 600 "$dir/.env"
}

make_env ai-stack   WEBUI_SECRET_KEY:32 N8N_ENCRYPTION_KEY:32 POSTGRES_N8N_PASSWORD:24 SEARXNG_SECRET:32
make_env monitoring GRAFANA_ADMIN_PASSWORD:16

echo
echo "Where are the secrets?"
echo "  $(pwd)/ai-stack/.env      (hidden file: 'ls -a ai-stack' to see it)"
echo "  $(pwd)/monitoring/.env"
echo
echo "To remember:"
echo "  • Grafana password (user 'admin'):"
echo "        grep GRAFANA_ADMIN_PASSWORD monitoring/.env"
echo "  • BACK UP ai-stack/.env somewhere: without N8N_ENCRYPTION_KEY, the credentials"
echo "    stored in n8n become unreadable if you rebuild the machine."
echo
echo "Next step:   ./3-demarrer.sh"
