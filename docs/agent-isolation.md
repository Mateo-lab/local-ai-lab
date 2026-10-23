# Network isolation of the agents (Hermes, OpenClaw)

Goal: an agent can be manipulated by what it reads (prompt injection) or badly configured (OpenClaw's first test message
went to `api.openai.com`, see [openclaw.md](openclaw.md)). So it loses every network access it does not need: **no
Internet, no local network, not even the AI machine itself**. It only keeps the local model (Ollama), tracing
(Langfuse), and, for Hermes, SSH to the test machines you have explicitly allowed.

## 1. What each agent can reach

| Destination | Hermes | OpenClaw |
|---|---|---|
| Ollama (`http://ollama:11434`) | yes (`hermes-net` network) | yes (`llm-net` network) |
| Langfuse (`http://langfuse-web:3000`) | yes (`obs-net` network) | no |
| Test machines in `LAB_AGENT_SSH_ALLOW` (SSH) | yes, only these addresses and ports | no |
| Internet | **no** | **no** |
| Local network, VPN, other machines | **no** | **no** |
| The AI machine itself (SSH, remote desktop, service ports) | **no** | **no** |
| Its web interface from your PC (SSH tunnel) | not applicable | yes (`127.0.0.1:18789`, incoming connection) |

Ollama, Open WebUI, SearXNG, n8n… are not affected: they keep their normal access (model downloads, web search),
through the `ai-net` network.

## 2. How it is done

Two complementary mechanisms:

1. **"Internal" Docker networks** (`ai-stack/docker-compose.yml`): `llm-net`, `hermes-net` and `obs-net` have
   `internal: true`. Docker gives them no route to the outside; the connected containers can only talk to each other
   there. Ollama and Open WebUI, also connected to `ai-net`, go out through that one.
2. **Firewall** (`scripts/isolation-agents.sh`, `lab isolation` command) for the two networks that cannot be internal:
   - `hermes-sortie` (*sortie* = exit; interface `br-hermes-out`, `hermes/docker-compose.yml`): Hermes's only route to
     the outside. Everything is blocked there except the addresses in `LAB_AGENT_SSH_ALLOW` (TCP, port 22 by default).
   - `openclaw_default` (created by OpenClaw's official compose): needed to publish the web interface. Every
     **outgoing** connection is blocked there; **incoming** connections (your tunnel) and their replies go through.

   The rules are in two iptables chains: `AI-LAB-AGENTS` (called from `DOCKER-USER`, traffic crossing the machine) and
   `AI-LAB-AGENTS-HOTE` (*hôte* = host; called from `INPUT`, traffic to the machine itself, blocked from the agents'
   networks except replies). Blocked packets are logged (at most 6 per minute) with the prefix
   `ai-lab agent blocked:`: `sudo journalctl -k | grep "ai-lab agent"`.

The systemd service `ai-lab-isolation` reapplies the rules every time Docker starts.

## 3. Setup

1. In `lab.conf`, the test machines Hermes must be able to reach over SSH (otherwise, leave empty):
   ```
   LAB_AGENT_SSH_ALLOW="192.168.1.60"            # several: "192.168.1.60 192.168.1.61:2222"
   ```
2. Internal networks: on a **new** installation, nothing to do (`./3-demarrer.sh` creates them that way). On an
   **existing** installation, Docker does not change a network already created: it must be recreated (§7).
3. Firewall:
   ```bash
   lab isolation install     # systemd service + immediate application (asks for sudo)
   lab isolation test        # checks from inside the containers
   ```
4. `lab doctor` then checks that the three networks are internal and that the service is active.

## 4. Checking: `lab isolation test`

The test opens real connections from inside the containers and compares them with the expected result:

| Check | Expected |
|---|---|
| Ollama (`ollama:11434`) | reachable |
| Internet (`1.1.1.1:443`, `example.com:443`) | blocked |
| The AI machine (its address on the network, and its address on the Docker network), port 22 | blocked |
| Each machine in `LAB_AGENT_SSH_ALLOW` (Hermes) | reachable (if it is on and runs SSH) |

For Hermes, the test starts a temporary container (`docker compose run --rm`) with `python3`; for OpenClaw, it runs
inside the gateway with `node`. `lab isolation status` shows the rules and the number of blocked packets.

## 5. The test machine (Hermes's SSH link)

The AI machine's firewall lets Hermes open SSH to the machines in `LAB_AGENT_SSH_ALLOW`. Through that link, Hermes could
still reach the Internet in two ways; both are closed:

| Path | Protection |
|---|---|
| **SSH tunnel** (port forwarding `-L`, SOCKS proxy `-D`, `-W`) through the test machine | `restrict` option on Hermes's key (set by `lab remote add`) **and**, on the SSH server side, for its account: `AllowTcpForwarding no`, `AllowStreamLocalForwarding no`, `PermitTunnel no`, `AllowAgentForwarding no`, `X11Forwarding no`, `GatewayPorts no` (a reverse forward `-R` cannot be opened to the machine's network; already excluded by `AllowTcpForwarding no`, kept as a second layer) |
| **Commands run on the test machine** (PowerShell, `curl`…) that go out through its connection | Internet cut for the **whole** machine by its firewall: outbound block rules to every public address (IPv4 and IPv6) and to DNS (port 53, which would allow data to leave through queries to the router). The local network stays reachable |

Why the whole machine? The Windows firewall cannot block the Internet for a single local account (per-user filtering
only applies to traffic authenticated by IPsec): only a machine-wide rule is reliable. An account without administrator
rights, like Hermes's, cannot change it.

**Setup**, on the Windows test machine, in PowerShell **as administrator**, with the file
`windows\outils\Isoler-machine-de-test.ps1` copied to that machine:

```powershell
powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1          # agent account: hermes
powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1 -Undo    # give the Internet back to the machine
```

The script backs up the firewall configuration and `sshd_config` (in `C:\ProgramData\ssh`), adds the rules (group
"local-ai-lab isolation"), adds the SSH options to the `Match User hermes` block (checked by `sshd -t`, previous version
restored on error), then checks that the Internet and DNS are blocked.

**Check from the AI machine**, through Hermes's eyes: `lab remote test NAME`. Expected lines:
`SSH tunnel refused: good`, `Internet from the machine: blocked, good`, `DNS from the machine: blocked, good`.

**Consequences**: no more Internet for anyone on this machine (Windows updates included). For an update: `-Undo`, the
update, then run the script again. If the test machine is only reachable through a VPN client installed on the machine
itself, that client will no longer be able to connect: check before.

## 6. Consequences to know

- **Hermes**: no more web search, package downloads (`pip`, `npm`), browser tools, or plugin installation from the
  Internet (for example `plugins install langfuse`). For a one-off installation: `lab isolation remove`, the
  installation, then `lab isolation apply` right after. `hermes-net` and `obs-net` stay internal meanwhile: only the
  `hermes-sortie` route is opened.
- **OpenClaw**: no more web search, messaging channels (Discord, Telegram…), or hosted model, even selected by mistake:
  the request is blocked before leaving the machine.
- **Updates**: images and code (`docker pull`, `git pull`) are downloaded by the machine, not by the agents: they keep
  working.
- **OpenClaw recreated** (update, `docker compose down`): its network may get a new identifier. `openclaw/install.sh`
  reapplies the rules; otherwise `lab isolation apply`. `lab isolation status` reports a network that is not covered.

## 7. Switching an existing installation to internal networks

The `llm-net`, `hermes-net` and `obs-net` networks must be deleted then recreated. The **data is not touched** (it is
in the volumes, and what Hermes keeps is in `hermes/data`); the services concerned restart (≈ 1 minute): `ai-stack`
(Ollama, Open WebUI…), the portal, Langfuse, the OpenClaw gateway.

Pitfall met on the reference machine: **orphan Hermes sessions** (`hermes-hermes-run-…` containers still running days
after their terminal was closed) prevented the networks from being deleted. The script below removes them, then checks
each step and **stops** at the first problem. Paste the whole block:

```bash
bash <<'EOF'
set -euo pipefail
cd ~/Documents/ai-lab
internal() { [ "$(docker network inspect -f '{{.Internal}}' "$1" 2>/dev/null)" = true ]; }
echo "1. Hermes sessions still running (hermes/data is not touched)"
docker ps -a --filter name=hermes-hermes-run --format '   {{.Names}}  {{.Status}}'
docker ps -aq --filter name=hermes-hermes-run | xargs -r docker rm -f
echo "2. Stopping what is connected to the networks (WITHOUT -v: volumes and data stay)"
(cd ~/openclaw 2>/dev/null && docker compose -f docker-compose.yml down) || true
[ ! -f langfuse/app/docker-compose.yml ] || (cd langfuse/app && docker compose down)
(cd portail && docker compose down)
(cd ai-stack && docker compose down)
echo "3. Deleting the non-internal networks"
for n in llm-net hermes-net obs-net; do
  if docker network inspect "$n" >/dev/null 2>&1 && ! internal "$n"; then
    docker network rm "$n" || { echo "STOP: $n still used by: $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$n")"; exit 1; }
  fi
done
echo "4. Restarting"
lab start
for n in llm-net hermes-net obs-net; do internal "$n" || { echo "STOP: $n is not internal"; exit 1; }; done
[ -n "$(docker ps -q --filter name=^ollama$)" ] || { echo "STOP: Ollama is not running (lab logs ollama)"; exit 1; }
if [ -d ~/openclaw ]; then
  (cd ~/openclaw && docker compose -f docker-compose.yml up -d --force-recreate openclaw-gateway)
  docker network connect llm-net openclaw-openclaw-gateway-1 2>/dev/null || true
fi
echo "5. Firewall and check"
if systemctl is-active --quiet ai-lab-isolation.service; then lab isolation apply; else lab isolation install; fi
lab isolation test
lab doctor | tail -9
EOF
```

If a `STOP` appears, nothing else is done after that point; `lab start` restarts the services on the existing networks
(without isolation) while you fix it.

**Never `docker compose down -v`**: `-v` would delete the volumes (models, conversations, workflows).

## 8. Reverting

- Firewall only: `lab isolation uninstall`.
- Networks: remove the three `internal: true` lines from `ai-stack/docker-compose.yml` and redo §7.

## What is not verified

- **Verified on the reference machine** (Docker 29.9, iptables): `lab isolation test` succeeds for OpenClaw and Hermes
  (Ollama reachable; Internet by IP and by name blocked; host machine blocked; allowed test machine reachable over SSH).
  The §7 script is the version fixed after the first pass (orphan Hermes sessions): its complete form has not been
  replayed.
- A reboot of the machine (rules reapplied by the systemd service) has not been observed yet.
- The behaviour of OpenClaw's installation wizard (`setup.sh`) when isolation is already active: if it needs the
  Internet, disable it for the time of the installation (`lab isolation remove`).
- IPv6 is not filtered: the lab's Docker networks do not have IPv6 enabled. If you enable it, these rules are no longer
  enough.
- **Test machine: verified** on the reference Windows machine, with `lab remote test`: SSH tunnel refused, Internet and
  DNS blocked from the machine, the agent's SSH connection still possible. Before the script, the same test showed
  `internet=True dns=True`.
- The rules target Docker's iptables firewall (Ubuntu's default case); with Docker's native nftables firewall, they
  would not apply.
