#!/usr/bin/env bash
# Teste panel/panel.py avec de faux `lab` et `dev.sh` (aucun Docker, aucun modèle).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'kill $PID 2>/dev/null; rm -rf "$T"' EXIT
fail=0; ok() { echo "  ✓ $1"; }; ko() { echo "  ✗ $1"; fail=1; }
mkdir -p "$T/state"; echo images > "$T/state/mode"
cat > "$T/lab" <<'S'
#!/usr/bin/env bash
echo "lab $*"; printf '\033[31mrouge\033[0m\033]0;titre\007fin\n'
[ "$1" = update ] && sleep 3
exit 0
S
cat > "$T/dev.sh" <<'S'
#!/usr/bin/env bash
case "$1" in
 pending) printf 'essai\tagent/slugify\t3\nessai\tagent/$(touch /tmp/PWNED)\t1\nBAD NAME\tagent/x\t1\n' ;;
 *) echo "dev $*" ;;
esac
S
chmod +x "$T/lab" "$T/dev.sh"
PORT=$((20000 + RANDOM % 20000))
PANEL_LAB="$T/lab" PANEL_DEV="$T/dev.sh" PANEL_STATE="$T/state" PANEL_TOKEN_FILE="$T/cfg/token" PANEL_PORT=$PORT python3 "$ROOT/panel/panel.py" >"$T/log" 2>&1 & PID=$!
for _ in $(seq 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.25; done
TOK="$(cat "$T/cfg/token")"; U="http://127.0.0.1:$PORT"; J="$T/jar"
code() { curl -s -o "$T/out" -w '%{http_code}' "$@"; }
[ "$(stat -c %a "$T/cfg/token")" = 600 ] && ok "jeton en 0600" || ko "droits du jeton"
[ "$(code "$U/")" = 401 ] && ok "page refusée sans cookie" || ko "page sans cookie"
[ "$(code "$U/api/etat" -H 'X-Panel: 1')" = 403 ] && ok "API refusée sans cookie" || ko "API sans cookie"
[ "$(code "$U/login?t=mauvais")" = 403 ] && ok "mauvais jeton refusé" || ko "mauvais jeton"
[ "$(code "$U/login?t=é")" = 403 ] && ok "jeton non ASCII sans plantage" || ko "jeton non ASCII"
[ "$(code -c "$J" "$U/login?t=$TOK")" = 302 ] && ok "login accepté" || ko "login"
grep -q HttpOnly "$J" && ok "cookie HttpOnly" || ko "cookie HttpOnly"
[ "$(code -b "$J" "$U/")" = 200 ] && ok "page servie avec cookie" || ko "page avec cookie"
[ "$(code -b "$J" "$U/" -H 'Host: evil.example')" = 403 ] && ok "Host étranger refusé (DNS rebinding)" || ko "Host étranger"
[ "$(code -b "$J" "$U/api/etat")" = 403 ] && ok "API sans X-Panel refusée" || ko "X-Panel"
[ "$(code -b "$J" "$U/api/etat" -H 'X-Panel: 1' -H 'Origin: http://evil.example')" = 403 ] && ok "Origin étrangère refusée" || ko "Origin"
[ "$(code -b "$J" "$U/api/etat" -H 'X-Panel: 1')" = 200 ] && grep -q '"mode": "images"' "$T/out" && ok "état + mode lu" || ko "état"
P() { code -b "$J" -X POST "$U/api/run" -H 'X-Panel: 1' -H 'Content-Type: application/json' -d "$1"; }
[ "$(P '{"action":"rm -rf /"}')" = 400 ] && ok "action hors liste refusée" || ko "allowlist"
[ "$(P '{"action":"mode-agents"}')" = 202 ] && ok "action lancée" || ko "lancement"
sleep 1
curl -s -b "$J" -H 'X-Panel: 1' "$U/api/job?depuis=0" > "$T/job"
grep -q 'lab mode agents' "$T/job" && ok "sortie diffusée" || ko "sortie"
grep -q 'u001b\|\\u0007' "$T/job" && ko "séquences d'échappement non filtrées" || ok "séquences d'échappement retirées"
[ "$(P '{"action":"update"}')" = 202 ] && ok "update lancée" || ko "update"
[ "$(P '{"action":"doctor"}')" = 409 ] && ok "deuxième action refusée (409)" || ko "verrou"
sleep 4
[ "$(P '{"action":"hermes-revue","projet":"essai","branche":"agent/slugify"}')" = 202 ] && ok "revue d'une branche listée" || ko "revue"
sleep 1
[ "$(P '{"action":"hermes-revue","projet":"essai","branche":"agent/$(touch /tmp/PWNED)"}')" = 400 ] && ok "branche piégée refusée" || ko "branche piégée"
[ "$(P '{"action":"hermes-revue","projet":"essai","branche":"agent/inconnue"}')" = 400 ] && ok "branche absente de la liste refusée" || ko "branche inconnue"
[ "$(P '{"action":"hermes-revue","projet":"../x","branche":"agent/a"}')" = 400 ] && ok "projet invalide refusé" || ko "projet invalide"
[ "$(P '{"action":"hermes-fusion","projet":"essai","branche":"agent/slugify"}')" = 400 ] && ok "fusion sans confirmation refusée" || ko "fusion sans confirmation"
[ "$(P '{"action":"hermes-fusion","projet":"essai","branche":"agent/slugify","confirme":true}')" = 202 ] && ok "fusion confirmée" || ko "fusion"
sleep 1; curl -s -b "$J" -H 'X-Panel: 1' "$U/api/job" | grep -q 'merge essai agent/slugify --yes' && ok "fusion appelle merge --yes" || ko "arguments de fusion"
curl -s -b "$J" -H 'X-Panel: 1' "$U/api/hermes" > "$T/h"
[ "$(grep -o '"projet"' "$T/h" | wc -l)" = 1 ] && ok "liste Hermes filtrée (1 branche valide sur 3 lignes)" || ko "liste Hermes"
[ ! -e /tmp/PWNED ] && ok "aucune injection exécutée" || ko "injection exécutée"
[ "$(code -b "$J" -X POST "$U/api/run" -H 'X-Panel: 1' -d "$(head -c 9000 /dev/zero | tr '\0' a)")" = 413 ] && ok "corps trop gros refusé" || ko "taille du corps"
curl -si -b "$J" "$U/" | grep -qi 'content-security-policy' && ok "en-tête CSP présent" || ko "CSP"
[ $fail = 0 ] && echo "Tous les tests du panneau passent." || { echo "ÉCHECS"; cat "$T/log"; exit 1; }
