#!/usr/bin/env bash
# Tests `lab mode agents [hermes|openclaw]|normal|status` and the `lab doctor` agent check with a FAKE docker
# (no real container, no GPU). Checks which containers are stopped/started and the guards.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "  ✓ $1"; }; ko() { echo "  ✗ $1"; fail=1; }
mkdir -p "$T/bin" "$T/proj"; cp "$ROOT/lab" "$T/proj/lab"
OC=openclaw-openclaw-gateway-1
ALL="ollama open-webui n8n kokoro tika searxng qdrant postgres-n8n comfyui prometheus grafana homepage $OC"
printf '%s\n' $ALL > "$T/running"; printf '%s\n' $ALL > "$T/known"
cat > "$T/bin/docker" <<'S'
#!/usr/bin/env bash
R="$FAKE/running"
case "$1" in
  ps) q=0; name=""; fmt=0; shift
      while [ $# -gt 0 ]; do case "$1" in -q) q=1;; -f) shift; name="${1#name=^}"; name="${name%\$}";; --format) shift; fmt=1;; esac; shift; done
      if [ -n "$name" ]; then grep -qx "$name" "$R" && echo "id-$name"; exit 0; fi
      cat "$R" ;;
  stop) shift; for c in "$@"; do grep -qx "$c" "$R" && sed -i "/^$c\$/d" "$R"; done; exit 0 ;;
  start) shift; for c in "$@"; do grep -qx "$c" "$FAKE/known" || exit 1; grep -qx "$c" "$R" || echo "$c" >> "$R"; done; exit 0 ;;
  inspect) shift; grep -qx "${!#}" "$FAKE/known" ;;
  *) exit 0 ;;
esac
S
chmod +x "$T/bin/docker"
export FAKE="$T" PATH="$T/bin:$PATH"
L="$T/proj/lab"; up() { grep -qx "$1" "$T/running"; }

echo "· lab mode agents (default hermes)"
out="$("$L" mode agents 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "exit 0" || ko "exit $rc: $out"
for c in open-webui n8n kokoro tika searxng qdrant postgres-n8n comfyui "$OC"; do up "$c" && ko "$c still running" || ok "$c stopped"; done
for c in ollama prometheus grafana homepage; do up "$c" && ok "$c kept" || ko "$c stopped by mistake"; done
[ "$(cat "$T/proj/.lab/agent")" = hermes ] && ok "agent=hermes stored" || ko "agent file"
st="$("$L" mode status 2>&1)"; grep -q "Mode: agents (agent: hermes)" <<<"$st" && ok "status shows the agent" || ko "status: $st"

echo "· refuses to switch to openclaw while a Hermes session is open"
echo hermes-session-20261026-100000-1 >> "$T/running"; echo hermes-session-20261026-100000-1 >> "$T/known"
out="$("$L" mode agents openclaw 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "nothing was changed" && ok "refused" || ko "should refuse: $out"
up "$OC" && ko "OpenClaw started despite the refusal" || ok "OpenClaw untouched"
[ "$(cat "$T/proj/.lab/agent")" = hermes ] && ok "state unchanged" || ko "state changed"
sed -i '/^hermes-session-/d' "$T/running"

echo "· lab mode agents openclaw"
out="$("$L" mode agents openclaw 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "exit 0" || ko "exit $rc: $out"
up "$OC" && ok "OpenClaw started" || ko "OpenClaw not started"
up open-webui && ko "open-webui running" || ok "open-webui stopped"
[ "$(cat "$T/proj/.lab/agent")" = openclaw ] && ok "agent=openclaw stored" || ko "agent file"

echo "· doctor warns about a second agent"
echo hermes-session-20261026-100000-2 >> "$T/running"
dr="$("$L" doctor 2>&1)"; grep -q "a Hermes session is open" <<<"$dr" && ok "warning (openclaw mode + Hermes session)" || ko "no warning"
sed -i '/^hermes-session-/d' "$T/running"

echo "· back to hermes then normal"
"$L" mode agents hermes >/dev/null 2>&1; up "$OC" && ko "OpenClaw should be stopped" || ok "OpenClaw stopped again"
[ -f "$T/proj/.lab/openclaw-paused" ] && ok "marker set" || ko "no marker"
"$L" mode normal >/dev/null 2>&1
for c in open-webui n8n kokoro tika searxng qdrant postgres-n8n "$OC"; do up "$c" && ok "$c restarted" || ko "$c not restarted"; done
up comfyui && ko "comfyui must NOT be restarted by normal" || ok "comfyui stays stopped"
[ -f "$T/proj/.lab/openclaw-paused" ] && ko "marker still there" || ok "marker removed"

echo "· invalid agent"
"$L" mode agents foo >/dev/null 2>&1 && ko "foo accepted" || ok "foo refused"
[ $fail -eq 0 ] && echo "All good." || { echo "FAILURES"; exit 1; }
