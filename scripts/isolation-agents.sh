#!/usr/bin/env bash
# Coupe les agents (Hermes, OpenClaw) d'Internet, du réseau local et de la machine hôte.
# Seule exception : SSH de Hermes vers les machines de test listées dans lab.conf (LAB_AGENT_SSH_ALLOW).
#
#   lab isolation install     installe le service systemd (réapplique au démarrage de Docker) et applique
#   lab isolation apply       (re)crée les règles maintenant
#   lab isolation status      affiche les règles et leurs compteurs
#   lab isolation test        vérifie depuis l'intérieur des conteneurs (Internet bloqué, Ollama joignable…)
#   lab isolation remove      retire les règles (les réseaux internes restent sans sortie)
#   lab isolation uninstall   retire le service et les règles
#
# Fonctionnement (détail : docs/isolation-agents.md) :
# - llm-net, hermes-net, obs-net sont des réseaux Docker « internes » (ai-stack/docker-compose.yml) : aucune sortie.
# - Hermes a un réseau de sortie dédié (hermes-sortie, interface br-hermes-out) : tout y est bloqué sauf
#   LAB_AGENT_SSH_ALLOW.
# - OpenClaw a besoin d'un réseau non interne pour publier son interface (openclaw_default) : toute connexion
#   SORTANTE de ce réseau est bloquée ; les connexions entrantes (ton tunnel SSH) et leurs réponses passent.
# - Chaîne AI-LAB-AGENTS (appelée par DOCKER-USER) : trafic qui traverse la machine. Chaîne AI-LAB-AGENTS-HOTE
#   (appelée par INPUT) : trafic vers la machine elle-même (SSH, bureau à distance…), bloqué depuis ces réseaux.
# IPv4 seulement : les réseaux Docker du lab n'ont pas d'IPv6.
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

die() { echo "isolation : $*" >&2; exit 1; }
as_root() { [ "$(id -u)" -eq 0 ] || exec sudo -- "$SELF" "$@"; }
bridge_of() { # bridge_of RESEAU -> nom de l'interface sur la machine (vide si le réseau n'existe pas)
  local id name
  id="$(docker network inspect -f '{{.Id}}' "$1" 2>/dev/null)" || return 0
  name="$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$1" 2>/dev/null)"
  if [ -n "$name" ] && [ "$name" != "<no value>" ]; then echo "$name"; else echo "br-${id:0:12}"; fi
}
allow_list() { # « IP » ou « IP:PORT » -> « IP PORT », valeurs vérifiées
  local a ip port
  for a in $ALLOW; do
    ip="${a%%:*}"; port=22; [[ "$a" == *:* ]] && port="${a##*:}"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "LAB_AGENT_SSH_ALLOW : adresse IPv4 invalide « $a »"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "LAB_AGENT_SSH_ALLOW : port invalide « $a »"
    echo "$ip $port"
  done
}

cmd_apply() {
  as_root apply
  command -v iptables >/dev/null || die "iptables introuvable"
  iptables -n -L DOCKER-USER >/dev/null 2>&1 || die "chaîne DOCKER-USER absente : Docker est-il démarré (pare-feu iptables) ?"
  local oc internes=() n b ip port
  oc="$(bridge_of "$OC_NET")"
  for n in llm-net hermes-net obs-net; do b="$(bridge_of "$n")"; [ -n "$b" ] && internes+=("$b"); done
  for n in llm-net hermes-net obs-net; do
    [ "$(docker network inspect -f '{{.Internal}}' "$n" 2>/dev/null)" = "true" ] \
      || echo "ATTENTION : le réseau $n n'est pas interne (ou absent) : les conteneurs qui y sont reliés peuvent sortir. Voir docs/isolation-agents.md." >&2
  done

  iptables -N "$CH" 2>/dev/null || iptables -F "$CH"
  iptables -N "$CHH" 2>/dev/null || iptables -F "$CHH"
  iptables -C DOCKER-USER -j "$CH" 2>/dev/null || iptables -I DOCKER-USER 1 -j "$CH"
  iptables -C INPUT -j "$CHH" 2>/dev/null || iptables -I INPUT 1 -j "$CHH"

  # 1. Trafic qui traverse la machine (vers Internet, le réseau local, d'autres réseaux Docker)
  iptables -A "$CH" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  while read -r ip port; do
    [ -n "$ip" ] || continue
    iptables -A "$CH" -i "$BR_HERMES" -d "$ip" -p tcp --dport "$port" -j RETURN
    echo "  exception : Hermes → $ip port $port (SSH)"
  done < <(allow_list)
  iptables -A "$CH" -i "$BR_HERMES" -m limit --limit 6/min -j LOG --log-prefix "ai-lab agent bloque: "
  iptables -A "$CH" -i "$BR_HERMES" -j DROP
  if [ -n "$oc" ]; then
    iptables -A "$CH" -i "$oc" -o "$oc" -j RETURN
    iptables -A "$CH" -i "$oc" -m limit --limit 6/min -j LOG --log-prefix "ai-lab agent bloque: "
    iptables -A "$CH" -i "$oc" -j DROP
  else
    echo "  (réseau $OC_NET absent : OpenClaw non installé ; relance « lab isolation apply » après l'avoir installé)"
  fi

  # 2. Trafic vers la machine elle-même : seules les réponses à ce que la machine a ouvert passent
  for b in "$BR_HERMES" ${oc:+"$oc"} "${internes[@]}"; do
    iptables -A "$CHH" -i "$b" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    iptables -A "$CHH" -i "$b" -j DROP
  done
  echo "Isolation des agents appliquée (Hermes : $BR_HERMES ; OpenClaw : ${oc:-absent} ; réseaux internes : ${internes[*]:-aucun})."
}

cmd_remove() {
  as_root remove
  iptables -D DOCKER-USER -j "$CH" 2>/dev/null || true
  iptables -D INPUT -j "$CHH" 2>/dev/null || true
  iptables -F "$CH" 2>/dev/null || true; iptables -X "$CH" 2>/dev/null || true
  iptables -F "$CHH" 2>/dev/null || true; iptables -X "$CHH" 2>/dev/null || true
  echo "Règles retirées. Les réseaux internes (llm-net, hermes-net, obs-net) restent sans sortie."
}

cmd_status() {
  as_root status
  echo "Service : $(systemctl is-active ai-lab-isolation.service 2>/dev/null) (au démarrage : $(systemctl is-enabled ai-lab-isolation.service 2>/dev/null))"
  local n; for n in llm-net hermes-net obs-net hermes-sortie "$OC_NET"; do
    printf '  %-16s interne=%-5s interface=%s\n' "$n" "$(docker network inspect -f '{{.Internal}}' "$n" 2>/dev/null || echo absent)" "$(bridge_of "$n")"
  done
  echo "--- $CH (trafic traversant ; paquets, octets, règle) :"; iptables -L "$CH" -v -n 2>/dev/null | tail -n +3 || echo "  (absente)"
  echo "--- $CHH (trafic vers la machine) :"; iptables -L "$CHH" -v -n 2>/dev/null | tail -n +3 || echo "  (absente)"
  local oc; oc="$(bridge_of "$OC_NET")"
  if [ -n "$oc" ] && ! iptables -S "$CH" 2>/dev/null | grep -q -- "-i $oc "; then
    echo "ATTENTION : le réseau d'OpenClaw ($oc) n'est pas couvert (recréé depuis ?) : lab isolation apply" >&2
  fi
}

cmd_install() {
  as_root install
  cat > "$UNIT" <<UNIT
[Unit]
Description=Isolation réseau des agents IA (local-ai-lab : lab isolation)
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
  echo "Service installé : ai-lab-isolation (réapplique les règles à chaque démarrage de Docker)."
  systemctl --no-pager --lines=8 status ai-lab-isolation.service | sed -n '1,3p;/exception\|appliquée\|ATTENTION/p'
}

cmd_uninstall() {
  as_root uninstall
  systemctl disable --now ai-lab-isolation.service 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  cmd_remove
}

# --- Vérification depuis l'intérieur des conteneurs -------------------------------------------------
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
    ok = (got and want == "ouvert") or (not got and want == "bloque")
    res |= (not ok)
    print(("  OK   " if ok else "  ÉCHEC ") + label + " : " + ("joignable" if got else "bloqué") + " (attendu : " + want + ")")
sys.exit(res)
'
cmd_test() {
  local gw_oc hostip rc=0 checks ip port
  hostip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  echo "OpenClaw ($OC_GW) :"
  if docker inspect "$OC_GW" >/dev/null 2>&1; then
    gw_oc="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$OC_NET" 2>/dev/null)"
    docker exec "$OC_GW" node -e '
const net=require("net"); const checks=process.argv.slice(1).map(l=>l.split("|")); let bad=0;
const tcp=(h,p)=>new Promise(r=>{const s=net.connect({host:h,port:+p});s.setTimeout(4000);
  s.on("connect",()=>{s.destroy();r(true)});s.on("timeout",()=>{s.destroy();r(false)});s.on("error",()=>r(false));});
(async()=>{for(const [l,h,p,w] of checks){const g=await tcp(h,p);const ok=(g&&w==="ouvert")||(!g&&w==="bloque");bad|=!ok;
  console.log((ok?"  OK   ":"  ÉCHEC ")+l+" : "+(g?"joignable":"bloqué")+" (attendu : "+w+")");} process.exit(bad);})();
' "Ollama (http://ollama:11434)|ollama|11434|ouvert" "Internet (1.1.1.1:443)|1.1.1.1|443|bloque" \
      "Internet par nom (example.com:443)|example.com|443|bloque" \
      "machine hôte, SSH (${hostip:-?}:22)|${hostip:-127.0.0.2}|22|bloque" \
      "machine hôte par le réseau Docker (${gw_oc:-?}:22)|${gw_oc:-127.0.0.2}|22|bloque" || rc=1
  else echo "  (conteneur absent : non testé)"; fi

  echo "Hermes (conteneur temporaire) :"
  checks=("Ollama (http://ollama:11434)|ollama|11434|ouvert" "Internet (1.1.1.1:443)|1.1.1.1|443|bloque"
          "Internet par nom (example.com:443)|example.com|443|bloque"
          "machine hôte, SSH (${hostip:-?}:22)|${hostip:-127.0.0.2}|22|bloque")
  while read -r ip port; do [ -n "$ip" ] && checks+=("machine de test autorisée ($ip:$port)|$ip|$port|ouvert"); done < <(allow_list)
  (cd "$ROOT/hermes" && docker compose run --rm --no-deps -T --entrypoint python3 hermes -c "$PROBE" "${checks[@]}") || rc=1
  [ $rc = 0 ] && echo "Isolation vérifiée." || echo "Au moins un contrôle a échoué : voir docs/isolation-agents.md." >&2
  return $rc
}

case "${1:-}" in
  apply) cmd_apply ;; remove) cmd_remove ;; status) cmd_status ;; install) cmd_install ;;
  uninstall) cmd_uninstall ;; test) cmd_test ;;
  *) sed -n '2,10p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
