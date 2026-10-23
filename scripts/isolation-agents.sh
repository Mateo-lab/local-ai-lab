#!/usr/bin/env bash
# Cuts the agents (Hermes, OpenClaw) off from the Internet, the local network and the host machine.
# Single exception: SSH from Hermes to the test machines listed in lab.conf (LAB_AGENT_SSH_ALLOW).
#
#   lab isolation install     installs the systemd service (reapplies when Docker starts) and applies
#   lab isolation apply       (re)creates the rules now
#   lab isolation status      shows the rules and their counters
#   lab isolation test        checks from inside the containers (Internet blocked, Ollama reachable…)
#   lab isolation remove      removes the rules (the internal networks stay without an exit)
#   lab isolation uninstall   removes the service and the rules
#
# How it works (details: docs/agent-isolation.md):
# - llm-net, hermes-net, obs-net are "internal" Docker networks (ai-stack/docker-compose.yml): no exit.
# - Hermes has a dedicated exit network (hermes-sortie, interface br-hermes-out): everything is blocked there except
#   LAB_AGENT_SSH_ALLOW.
# - OpenClaw needs a non-internal network to publish its interface (openclaw_default): every OUTGOING connection
#   from that network is blocked; incoming connections (your SSH tunnel) and their replies go through.
# - Chain AI-LAB-AGENTS (called from DOCKER-USER): traffic crossing the machine. Chain AI-LAB-AGENTS-HOTE (hote = host)
#   (called from INPUT): traffic to the machine itself (SSH, remote desktop…), blocked from these networks.
# IPv4 only: the lab's Docker networks have no IPv6.
set -euo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
if [ -f "$ROOT/lab.conf" ]; then . "$ROOT/lab.conf"; fi

ALLOW="${LAB_AGENT_SSH_ALLOW:-}"
CH=AI-LAB-AGENTS
CHH=AI-LAB-AGENTS-HOTE
BR_HERMES=br-hermes-out
UNIT=/etc/systemd/system/ai-lab-isolation.service
OC_NET="${LAB_OPENCLAW_NET:-openclaw_default}"
OC_GW="${LAB_OPENCLAW_GW:-openclaw-openclaw-gateway-1}"

die() { echo "isolation: $*" >&2; exit 1; }
as_root() { [ "$(id -u)" -eq 0 ] || exec sudo -- "$SELF" "$@"; }
bridge_of() { # bridge_of NETWORK -> name of the interface on the machine (empty if the network does not exist)
  local id name
  id="$(docker network inspect -f '{{.Id}}' "$1" 2>/dev/null)" || return 0
  name="$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$1" 2>/dev/null)"
  if [ -n "$name" ] && [ "$name" != "<no value>" ]; then echo "$name"; else echo "br-${id:0:12}"; fi
}
allow_list() { # "IP" or "IP:PORT" -> "IP PORT", values checked
  local a ip port
  for a in $ALLOW; do
    ip="${a%%:*}"; port=22; [[ "$a" == *:* ]] && port="${a##*:}"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "LAB_AGENT_SSH_ALLOW: invalid IPv4 address \"$a\""
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "LAB_AGENT_SSH_ALLOW: invalid port \"$a\""
    echo "$ip $port"
  done
}

cmd_apply() {
  as_root apply
  command -v iptables >/dev/null || die "iptables not found"
  iptables -n -L DOCKER-USER >/dev/null 2>&1 || die "DOCKER-USER chain missing: is Docker running (iptables firewall)?"
  local oc internes=() n b ip port
  oc="$(bridge_of "$OC_NET")"
  for n in llm-net hermes-net obs-net; do b="$(bridge_of "$n")"; [ -n "$b" ] && internes+=("$b"); done
  for n in llm-net hermes-net obs-net; do
    [ "$(docker network inspect -f '{{.Internal}}' "$n" 2>/dev/null)" = "true" ] \
      || echo "WARNING: the network $n is not internal (or missing): the containers connected to it can get out. See docs/agent-isolation.md." >&2
  done

  iptables -N "$CH" 2>/dev/null || iptables -F "$CH"
  iptables -N "$CHH" 2>/dev/null || iptables -F "$CHH"
  iptables -C DOCKER-USER -j "$CH" 2>/dev/null || iptables -I DOCKER-USER 1 -j "$CH"
  iptables -C INPUT -j "$CHH" 2>/dev/null || iptables -I INPUT 1 -j "$CHH"

  # 1. Traffic crossing the machine (to the Internet, the local network, other Docker networks)
  iptables -A "$CH" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  while read -r ip port; do
    [ -n "$ip" ] || continue
    iptables -A "$CH" -i "$BR_HERMES" -d "$ip" -p tcp --dport "$port" -j RETURN
    echo "  exception: Hermes → $ip port $port (SSH)"
  done < <(allow_list)
  iptables -A "$CH" -i "$BR_HERMES" -m limit --limit 6/min -j LOG --log-prefix "ai-lab agent blocked: "
  iptables -A "$CH" -i "$BR_HERMES" -j DROP
  if [ -n "$oc" ]; then
    iptables -A "$CH" -i "$oc" -o "$oc" -j RETURN
    iptables -A "$CH" -i "$oc" -m limit --limit 6/min -j LOG --log-prefix "ai-lab agent blocked: "
    iptables -A "$CH" -i "$oc" -j DROP
  else
    echo "  ($OC_NET network missing: OpenClaw not installed; run \"lab isolation apply\" again after installing it)"
  fi

  # 2. Traffic to the machine itself: only replies to what the machine opened go through
  for b in "$BR_HERMES" ${oc:+"$oc"} "${internes[@]}"; do
    iptables -A "$CHH" -i "$b" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    iptables -A "$CHH" -i "$b" -j DROP
  done
  echo "Agent isolation applied (Hermes: $BR_HERMES; OpenClaw: ${oc:-missing}; internal networks: ${internes[*]:-none})."
}

cmd_remove() {
  as_root remove
  iptables -D DOCKER-USER -j "$CH" 2>/dev/null || true
  iptables -D INPUT -j "$CHH" 2>/dev/null || true
  iptables -F "$CH" 2>/dev/null || true; iptables -X "$CH" 2>/dev/null || true
  iptables -F "$CHH" 2>/dev/null || true; iptables -X "$CHH" 2>/dev/null || true
  echo "Rules removed. The internal networks (llm-net, hermes-net, obs-net) stay without an exit."
}

cmd_status() {
  as_root status
  echo "Service: $(systemctl is-active ai-lab-isolation.service 2>/dev/null) (at boot: $(systemctl is-enabled ai-lab-isolation.service 2>/dev/null))"
  local n; for n in llm-net hermes-net obs-net hermes-sortie "$OC_NET"; do
    printf '  %-16s internal=%-5s interface=%s\n' "$n" "$(docker network inspect -f '{{.Internal}}' "$n" 2>/dev/null || echo missing)" "$(bridge_of "$n")"
  done
  echo "--- $CH (crossing traffic; packets, bytes, rule):"; iptables -L "$CH" -v -n 2>/dev/null | tail -n +3 || echo "  (missing)"
  echo "--- $CHH (traffic to the machine):"; iptables -L "$CHH" -v -n 2>/dev/null | tail -n +3 || echo "  (missing)"
  local oc; oc="$(bridge_of "$OC_NET")"
  if [ -n "$oc" ] && ! iptables -S "$CH" 2>/dev/null | grep -q -- "-i $oc "; then
    echo "WARNING: OpenClaw's network ($oc) is not covered (recreated since?): lab isolation apply" >&2
  fi
}

cmd_install() {
  as_root install
  cat > "$UNIT" <<UNIT
[Unit]
Description=Network isolation of the AI agents (local-ai-lab: lab isolation)
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF apply
ExecStop=$SELF remove

[Install]
WantedBy=docker.service
UNIT
  systemctl daemon-reload
  systemctl enable ai-lab-isolation.service >/dev/null
  systemctl restart ai-lab-isolation.service
  echo "Service installed: ai-lab-isolation (reapplies the rules every time Docker starts)."
  systemctl --no-pager --lines=8 status ai-lab-isolation.service | sed -n '1,3p;/exception\|applied\|WARNING/p'
}

cmd_uninstall() {
  as_root uninstall
  systemctl disable --now ai-lab-isolation.service 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  cmd_remove
}

# --- Check from inside the containers ---------------------------------------------------------------
PROBE='
import socket, sys
def tcp(host, port, t=4):
    try:
        socket.create_connection((host, port), timeout=t).close(); return True
    except Exception:
        return False
res = 0
for label, host, port, want in [l.split("|") for l in sys.argv[1:]]:
    got = tcp(host, int(port))
    ok = (got and want == "open") or (not got and want == "blocked")
    res |= (not ok)
    print(("  OK     " if ok else "  FAILED ") + label + ": " + ("reachable" if got else "blocked") + " (expected: " + want + ")")
sys.exit(res)
'
cmd_test() {
  local gw_oc hostip rc=0 checks ip port
  hostip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  echo "OpenClaw ($OC_GW):"
  if docker inspect "$OC_GW" >/dev/null 2>&1; then
    gw_oc="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$OC_NET" 2>/dev/null)"
    docker exec "$OC_GW" node -e '
const net=require("net"); const checks=process.argv.slice(1).map(l=>l.split("|")); let bad=0;
const tcp=(h,p)=>new Promise(r=>{const s=net.connect({host:h,port:+p});s.setTimeout(4000);
  s.on("connect",()=>{s.destroy();r(true)});s.on("timeout",()=>{s.destroy();r(false)});s.on("error",()=>r(false));});
(async()=>{for(const [l,h,p,w] of checks){const g=await tcp(h,p);const ok=(g&&w==="open")||(!g&&w==="blocked");bad|=!ok;
  console.log((ok?"  OK     ":"  FAILED ")+l+": "+(g?"reachable":"blocked")+" (expected: "+w+")");} process.exit(bad);})();
' "Ollama (http://ollama:11434)|ollama|11434|open" "Internet (1.1.1.1:443)|1.1.1.1|443|blocked" \
      "Internet by name (example.com:443)|example.com|443|blocked" \
      "host machine, SSH (${hostip:-?}:22)|${hostip:-127.0.0.2}|22|blocked" \
      "host machine through the Docker network (${gw_oc:-?}:22)|${gw_oc:-127.0.0.2}|22|blocked" || rc=1
  else echo "  (container missing: not tested)"; fi

  echo "Hermes (temporary container):"
  checks=("Ollama (http://ollama:11434)|ollama|11434|open" "Internet (1.1.1.1:443)|1.1.1.1|443|blocked"
          "Internet by name (example.com:443)|example.com|443|blocked"
          "host machine, SSH (${hostip:-?}:22)|${hostip:-127.0.0.2}|22|blocked")
  while read -r ip port; do [ -n "$ip" ] && checks+=("allowed test machine ($ip:$port)|$ip|$port|open"); done < <(allow_list)
  (cd "$ROOT/hermes" && docker compose run --rm --no-deps -T --entrypoint python3 hermes -c "$PROBE" "${checks[@]}") || rc=1
  [ $rc = 0 ] && echo "Isolation verified." || echo "At least one check failed: see docs/agent-isolation.md." >&2
  return $rc
}

case "${1:-}" in
  apply) cmd_apply ;; remove) cmd_remove ;; status) cmd_status ;; install) cmd_install ;;
  uninstall) cmd_uninstall ;; test) cmd_test ;;
  *) sed -n '2,10p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
