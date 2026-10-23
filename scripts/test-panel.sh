#!/usr/bin/env bash
# Tests panel/panel.py with fake `lab` and `dev.sh` (no Docker, no model).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'kill $PID 2>/dev/null; rm -rf "$T"' EXIT
fail=0; ok() { echo "  ✓ $1"; }; ko() { echo "  ✗ $1"; fail=1; }
mkdir -p "$T/state"; echo images > "$T/state/mode"
cat > "$T/lab" <<'S'
#!/usr/bin/env bash
echo "lab $*"; printf '\033[31mred\033[0m\033]0;title\007end\n'
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
[ "$(stat -c %a "$T/cfg/token")" = 600 ] && ok "token in 0600" || ko "token permissions"
[ "$(code "$U/")" = 401 ] && ok "page refused without cookie" || ko "page without cookie"
[ "$(code "$U/api/etat" -H 'X-Panel: 1')" = 403 ] && ok "API refused without cookie" || ko "API without cookie"
[ "$(code "$U/login?t=wrong")" = 403 ] && ok "wrong token refused" || ko "wrong token"
[ "$(code "$U/login?t=é")" = 403 ] && ok "non-ASCII token without crash" || ko "non-ASCII token"
[ "$(code -c "$J" "$U/login?t=$TOK")" = 302 ] && ok "login accepted" || ko "login"
grep -q HttpOnly "$J" && ok "cookie HttpOnly" || ko "cookie HttpOnly"
[ "$(code -b "$J" "$U/")" = 200 ] && ok "page served with cookie" || ko "page with cookie"
[ "$(code -b "$J" "$U/" -H 'Host: evil.example')" = 403 ] && ok "foreign Host refused (DNS rebinding)" || ko "foreign Host"
[ "$(code -b "$J" "$U/api/etat")" = 403 ] && ok "API without X-Panel refused" || ko "X-Panel"
[ "$(code -b "$J" "$U/api/etat" -H 'X-Panel: 1' -H 'Origin: http://evil.example')" = 403 ] && ok "foreign Origin refused" || ko "Origin"
[ "$(code -b "$J" "$U/api/etat" -H 'X-Panel: 1')" = 200 ] && grep -q '"mode": "images"' "$T/out" && ok "state + mode read" || ko "state"
P() { code -b "$J" -X POST "$U/api/run" -H 'X-Panel: 1' -H 'Content-Type: application/json' -d "$1"; }
[ "$(P '{"action":"rm -rf /"}')" = 400 ] && ok "action outside the list refused" || ko "allowlist"
[ "$(P '{"action":"mode-agents"}')" = 202 ] && ok "action started" || ko "start"
sleep 1
curl -s -b "$J" -H 'X-Panel: 1' "$U/api/job?depuis=0" > "$T/job"
grep -q 'lab mode agents' "$T/job" && ok "output streamed" || ko "output"
grep -q 'u001b\|\\u0007' "$T/job" && ko "escape sequences not filtered" || ok "escape sequences removed"
[ "$(P '{"action":"update"}')" = 202 ] && ok "update started" || ko "update"
[ "$(P '{"action":"doctor"}')" = 409 ] && ok "second action refused (409)" || ko "lock"
sleep 4
[ "$(P '{"action":"hermes-revue","projet":"essai","branche":"agent/slugify"}')" = 202 ] && ok "review of a listed branch" || ko "review"
sleep 1
[ "$(P '{"action":"hermes-revue","projet":"essai","branche":"agent/$(touch /tmp/PWNED)"}')" = 400 ] && ok "trapped branch refused" || ko "trapped branch"
[ "$(P '{"action":"hermes-revue","projet":"essai","branche":"agent/unknown"}')" = 400 ] && ok "branch absent from the list refused" || ko "unknown branch"
[ "$(P '{"action":"hermes-revue","projet":"../x","branche":"agent/a"}')" = 400 ] && ok "invalid project refused" || ko "invalid project"
[ "$(P '{"action":"hermes-fusion","projet":"essai","branche":"agent/slugify"}')" = 400 ] && ok "merge without confirmation refused" || ko "merge without confirmation"
[ "$(P '{"action":"hermes-fusion","projet":"essai","branche":"agent/slugify","confirme":true}')" = 202 ] && ok "merge confirmed" || ko "merge"
sleep 1; curl -s -b "$J" -H 'X-Panel: 1' "$U/api/job" | grep -q 'merge essai agent/slugify --yes' && ok "merge calls merge --yes" || ko "merge arguments"
curl -s -b "$J" -H 'X-Panel: 1' "$U/api/hermes" > "$T/h"
[ "$(grep -o '"projet"' "$T/h" | wc -l)" = 1 ] && ok "Hermes list filtered (1 valid branch out of 3 lines)" || ko "Hermes list"
[ ! -e /tmp/PWNED ] && ok "no injection run" || ko "injection run"
[ "$(code -b "$J" -X POST "$U/api/run" -H 'X-Panel: 1' -d "$(head -c 9000 /dev/zero | tr '\0' a)")" = 413 ] && ok "body too large refused" || ko "body size"
curl -si -b "$J" "$U/" | grep -qi 'content-security-policy' && ok "CSP header present" || ko "CSP"
[ $fail = 0 ] && echo "All panel tests pass." || { echo "FAILURES"; cat "$T/log"; exit 1; }
