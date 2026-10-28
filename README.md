# local-ai-lab

A **fully local** AI lab on a single Linux machine with an NVIDIA GPU: chat (Open WebUI + Ollama), automation (n8n),
private web search, voice, documents, image generation (ComfyUI), agents (Hermes, OpenClaw) and their tracing
(Langfuse), monitoring and alerts on your phone, encrypted backups, and a benchmark bench. Everything is driven by a
single command, `lab`, and used from another computer over SSH, without exposing anything to the Internet.

- **Install**: [docs/installation.md](docs/installation.md) (from a fresh machine to access from your PC).
- **Remote access** (SSH, tunnels, remote desktop): [docs/remote-access.md](docs/remote-access.md).
- **Configure your installation**: a single file, `lab.conf` ([docs/configuration.md](docs/configuration.md)).
- **Security overview with diagrams**: [docs/security-architecture.md](docs/security-architecture.md).
- **All documentation**: [docs/README.md](docs/README.md).

Reference machine (where everything was built and measured): RTX 3090 24 GB, 64 GB of RAM, Ubuntu 26.04, called
**AiBeast** in the scripts. The lessons learned and measurements in the docs come from this machine. An installation on
other hardware has not been done yet: please report the problems you run into.

License: MIT (`LICENSE` file). The software started by the lab (Ollama, Open WebUI, n8n, ComfyUI, models…) keeps its own
license.

## Layout

Several separate Docker projects, each in its own folder. They only talk to each other through named networks, so that
each tool only sees what it needs.

```
ai-lab/
├── ai-stack/    Ollama + Open WebUI + n8n (+ dedicated Postgres) + Qdrant + SearXNG + Kokoro (voice) + Tika (documents)
├── monitoring/  Prometheus + Grafana + node-exporter + GPU exporter (+ alert rules)
├── portail/     Single home page (Homepage): all services, health lights, machine metrics
├── alerting/    Alerts: ntfy + Alertmanager + probes (blackbox)
├── hermes/      Hermes Agent (agent with sub-agents)           — optional
├── openclaw/    OpenClaw (agent, installed separately)          — optional
├── comfyui/     ComfyUI (image generation)                      — optional
├── langfuse/    Langfuse (tracing of agent calls)               — optional
├── bench/       Benchmark bench (speed, KV cache, context, GPU power) — optional
├── windows/     Windows shortcuts (button console, tunnels, deployment, backup copy, test machine tools)
├── scripts/     Encrypted backups, GPU power limit, client SSH config, agent isolation and access…
├── lab.conf.example   Settings specific to YOUR installation (copy to lab.conf)
├── docs/        Detailed documentation (index: docs/README.md)
├── lab          THE control command (lab doctor, lab start, lab update…)
└── 1-prerequis.sh … 8-stockage.sh    guided setup scripts, to run in order
```

```
 network         shared by                                    exit
 ai-net          the ai-stack services                        Internet
 llm-net         Ollama + OpenClaw   (OpenClaw only sees Ollama)   none (internal)
 hermes-net      Ollama + Hermes     (Hermes only sees Ollama)     none (internal)
 obs-net         Open WebUI + Hermes + Langfuse (traces only)  none (internal)
 mon-net         monitoring (isolated)
```

Every port is bound to `127.0.0.1`: nothing is visible on your local network. Details:
[docs/security-architecture.md](docs/security-architecture.md).

## Quick start

Prerequisites: Ubuntu or Debian, a working NVIDIA driver (`nvidia-smi`), an account with `sudo`, git. Details and model
choice for your GPU: [docs/installation.md](docs/installation.md).

In a terminal, with your normal user (**no `sudo` in front of the scripts**: they ask for the password themselves):

```bash
git clone https://github.com/Mateo-lab/local-ai-lab.git ~/Documents/ai-lab && cd ~/Documents/ai-lab
cp lab.conf.example lab.conf && nano lab.conf   # data disk, model, address for remote access
./1-prerequis.sh     # installs Docker + NVIDIA Container Toolkit, then:  sudo reboot
./2-secrets.sh       # creates the .env files with random passwords
./3-demarrer.sh MODEL_NAME   # starts ai-stack and monitoring, downloads the model
./lab install && lab start && lab doctor
lab isolation install   # cuts the agents off from the Internet (docs/agent-isolation.md)
lab client           # SSH configuration to paste on your PC (docs/remote-access.md)
```

Then, at your own pace and in any order (all optional):

```bash
./5-hermes.sh MODEL_NAME      # Hermes agent (see below)
./6-langfuse.sh               # agent tracing
./7-bench.sh check            # benchmark bench (see below)
./8-stockage.sh status        # 2nd SSD: formatting and moving Docker (optional)
./4-comfyui.sh                # images (only start when needed)
./openclaw/install.sh         # OpenClaw, last
```

**Where are the "secrets" / the `.env` files?** The scripts create them for you, you have nothing to write:

- `ai-stack/.env` and `monitoring/.env`
- `langfuse/app/.env` (created by `6-langfuse.sh`)

They are **hidden files** (their name starts with a dot): `ls` does not show them, use `ls -a ai-stack`. To read one:
`cat ai-stack/.env`. Grafana password: `grep GRAFANA_ADMIN_PASSWORD monitoring/.env`.

`./2-secrets.sh` can be run again at any time: it never overwrites a value, it only fills in missing variables (useful
after an update).

If a step fails, copy and paste the full error message.

## Where things are

### On the AI machine (Linux)

| Path | Content | Good to know |
|---|---|---|
| `~/Documents/ai-lab/` | **The project** (this folder, a git repository): compose files, scripts, `lab`, docs | This is where you run `./lab` |
| `…/ai-lab/lab.conf` | Settings of **this** installation | Never versioned; template: `lab.conf.example` |
| `…/ai-lab/*/.env` | Secrets of each project | Never overwritten by an update; backed up by `lab backup` |
| `…/ai-lab/.lab/` | Images recorded before each `lab update` (for `lab rollback`), current mode | Created at the first `lab update` |
| `…/ai-lab/bench/results/` | Benchmark results (CSV, HTML reports) | Backed up |
| `/data/docker/` (`LAB_DATA_DIR`) | Docker root: images, containers and **volumes** (Ollama models, Open WebUI, n8n, Qdrant, databases) | 4 TB SSD on the reference machine. `lab doctor` checks Docker is there |
| `/data/backups/restic/` | Encrypted backup repository | Same SSD as the data: see `docs/backups.md` §3 |
| `~/.config/aibeast-backup/password` | Password of the backup repository | Keep a copy somewhere other than the AI machine |
| `~/.local/bin/lab` | Link to `…/ai-lab/lab` | Created by `./lab install` |
| `~/.ssh/authorized_keys` | Keys allowed to log in over SSH | One line per device |
| `/etc/ssh/sshd_config.d/` | SSH hardening (no passwords, no reverse forwarding) | `docs/remote-access.md` |
| `/etc/systemd/system/gpu-power-limit.service` | Permanent GPU power limit | Created by `lab gpu-limit install` |
| `/etc/systemd/system/ai-lab-isolation.service` | Agent firewall | Created by `lab isolation install` |

Each service's data lives in named **Docker volumes** (under `/data/docker/volumes/`), not in the project folder:
`ai-stack_ollama_data` (models), `ai-stack_open_webui_data`, `ai-stack_n8n_data`, `ai-stack_qdrant_data`,
`ai-stack_postgres_n8n_data`, `monitoring_prometheus_data`, `monitoring_grafana_data`. **Never use
`docker compose down -v`**: it deletes these volumes.

### On your PC (client)

| Path (Windows; macOS/Linux: `~/.ssh/…`) | Content |
|---|---|
| `%USERPROFILE%\.ssh\id_ed25519` | Your **private** SSH key (never copy or send it) |
| `%USERPROFILE%\.ssh\id_ed25519.pub` | Your public key (the one in the AI machine's `authorized_keys`) |
| `%USERPROFILE%\.ssh\config` | `aibeast` shortcut and tunnels (block generated by `lab client`) |
| A working folder of your choice | The project's `windows\` folder, the `ai-lab.tar.gz` archive next to it (if you deploy from the PC), and `aibeast-backup\` (backup copy) |

## Addresses (on the machine)

| Service | URL |
|---|---|
| **Portal (entry point)** | http://127.0.0.1:3010 |
| Open WebUI | http://127.0.0.1:3000 |
| n8n | http://127.0.0.1:5678 |
| Qdrant | http://127.0.0.1:6333/dashboard |
| Ollama (API) | http://127.0.0.1:11434 |
| Grafana | http://127.0.0.1:3001 (user `admin`) |
| Prometheus | http://127.0.0.1:9090 |
| Langfuse | http://127.0.0.1:3002 |
| ComfyUI | http://127.0.0.1:8188 |
| OpenClaw | http://127.0.0.1:18789 |
| Alerts (ntfy) | http://127.0.0.1:2586/aibeast-alertes |
| Alertmanager | http://127.0.0.1:9093 |

From another computer: SSH tunnels, generated by `lab client` (one shortcut, `ssh -N aibeast`, opens them all). From
Windows, everything is ready in `windows/` (one double-click): see `docs/remote-access.md`.

## Driving the lab with `lab`

```bash
./lab install        # once: creates the `lab` command
lab doctor           # full health check (run it after every reboot)
lab start            # starts everything in order (ai-stack, monitoring, portail, alerting)
lab status | urls | logs SERVICE | models
lab update           # update with a backup first, then `lab rollback` if needed
```
Full reference: `docs/lab.md`. All documentation: `docs/README.md`.

## Command cheat sheet

On the AI machine, in a terminal. `lab` works from any folder after `./lab install`.

**Every day**

| I want to | Command |
|---|---|
| Check that everything is fine | `lab doctor` (after every reboot) |
| See the state (containers, GPU, disks) | `lab status` |
| Start / stop everything | `lab start` / `lab stop` (deletes nothing) |
| Start / stop a single project | `lab start ai-stack` (or `monitoring`, `portail`, `alerting`, `comfyui`, `langfuse`) / `lab stop comfyui` |
| See the addresses | `lab urls` |
| See a container's logs | `lab logs ollama` (Ctrl-C to quit) |
| See installed and loaded models | `lab models` |

**Images (ComfyUI)**

| I want to | Command |
|---|---|
| **Start ComfyUI** (recommended) | `lab mode images`: unloads the Ollama models from VRAM, starts ComfyUI, waits until it answers |
| Open it | `http://127.0.0.1:8188` on the AI machine; from Windows, double-click `Ouvrir-AiBeast.bat` then the same address |
| Stop ComfyUI and give the VRAM back to the models | `lab mode normal` |
| Start ComfyUI without unloading the models | `lab start comfyui` (the big loaded model and an image model do not fit together in VRAM) |
| Stop ComfyUI only | `lab stop comfyui` |
| See what it is doing | `lab logs comfyui` (the first start after the container is recreated can take ≈ 6–10 min) |

**Modes**

| I want to | Command |
|---|---|
| See the current mode and free VRAM | `lab mode status` |
| Free resources for the agents | `lab mode agents` (stops ComfyUI, Kokoro, Tika) |
| Go back to normal | `lab mode normal` |

**Maintenance**

| I want to | Command |
|---|---|
| Update the images (with a backup) | `lab update` |
| Go back to the previous images | `lab rollback` |
| Back up | `lab backup run`; `lab backup list`; `lab backup check`; `lab backup restore ID FOLDER`; `lab backup init` / `lab backup schedule` (once) |
| GPU power limit | `lab gpu-limit status`; `lab gpu-limit install 300`; `lab gpu-limit remove` |
| Remote desktop (≈ 100 W) | `lab desktop on` / `off` / `status` (`lab bureau` also works) |
| Agent isolation | `lab isolation status` / `test` |
| Small model for Open WebUI titles | `lab task-model NAME` (then a setting in the interface, see `docs/open-webui.md`) |

**Benchmarks** (they stop the production Ollama during the test; run them in `tmux`, they ask for `sudo`)

| I want to | Command |
|---|---|
| List the experiments | `lab bench` |
| Run an experiment | `lab bench kv-decode --model qwen3.8:27b` (others: `quick-smoke`, `power-sweep`, `power-confirm`, `context-scaling`, `ctx-window`, `kv-cache`, `kv-quality`, `prefix-cache`, `concurrency`) |
| See the plan without running anything | add `--dry-run` |
| Rebuild a report | `lab bench report bench/results/<folder>` |
| Understand the results | `docs/understanding-benchmarks.md` |

**Initial installation** (once, in order; no `sudo` in front)

`./1-prerequis.sh` (then `sudo reboot`) · `./2-secrets.sh` · `./3-demarrer.sh` · `./4-comfyui.sh` (or `lab mode images`) ·
`./5-hermes.sh MODEL` · `./6-langfuse.sh` · `./7-bench.sh check` · `./8-stockage.sh status` · `./openclaw/install.sh`

**From the Windows PC** (`windows\` folder, VPN connected, SSH key loaded). The simplest: double-click `AiBeast.bat`
(window with buttons). The individual scripts below are in `windows\outils\`.

| I want to | File to double-click |
|---|---|
| Open the tunnels to the interfaces | `Ouvrir-AiBeast.bat` (close them: `Fermer-tunnels-AiBeast.bat`) |
| Install or update the SSH configuration of this PC | `Installer-config-SSH.bat` |
| Copy the encrypted backups to this PC | `Sauvegarder-AiBeast-hors-machine.bat` |
| Send a new version of the lab to the AI machine | `Deployer-sur-AiBeast.bat` |

## Updating the lab

```bash
cd ~/Documents/ai-lab
git status            # must be clean (your settings are in lab.conf and the .env files, ignored by git)
git pull
./2-secrets.sh        # fills in variables added by the new version, without overwriting anything
lab start && lab doctor
```

You modify the lab yourself and deliver it from another PC? `scripts/release.sh` builds an archive of the committed
files, and `windows\outils\Deployer-sur-AiBeast.bat` sends and extracts it (it refuses if the AI machine's repository
has uncommitted changes): see [docs/windows-shortcuts.md](docs/windows-shortcuts.md).

## ai-stack: Ollama, Open WebUI, n8n, Qdrant, SearXNG, Kokoro, Tika

What scripts 2 and 3 do, in detail: `cd ai-stack`, `docker compose up -d`, `docker compose ps`.

**Back up `N8N_ENCRYPTION_KEY`** (in `ai-stack/.env`): without it, the credentials stored in n8n become unreadable if you
recreate the volume.

**n8n runs on PostgreSQL** (service `postgres-n8n`, no published port), not on SQLite. This database is separate from
Langfuse's, which ships its own.

### Model and context

```bash
docker exec ollama ollama list                       # downloaded models
docker exec -it ollama ollama pull MODEL_NAME
docker exec ollama ollama run MODEL_NAME "Say hello in one sentence"
docker exec ollama ollama ps      # PROCESSOR must show 100% GPU; CONTEXT = context actually served
```

`ollama ps` only lists **loaded** models: an empty list just means none is in memory. If PROCESSOR shows a CPU/GPU split,
the model or the context is too big for the GPU: lower `OLLAMA_CONTEXT_LENGTH` in `ai-stack/.env` (then
`docker compose up -d`) or pick a smaller model.

**Context**: Hermes requires at least 64,000 tokens and OpenClaw recommends it. The project default is 32768 (cautious):
set `OLLAMA_CONTEXT_LENGTH=65536` in `ai-stack/.env` for the agents, with the KV cache in `q8_0` (already enabled), and
check `ollama ps`. `lab dev ctx64` creates a 64k variant of the main model instead.

Connecting the tools: n8n → Ollama `http://ollama:11434`; n8n → Qdrant `http://qdrant:6333`. Open WebUI is already
configured for Ollama.

### Web search (SearXNG)

Private metasearch engine, no published port: only Open WebUI reaches it. The `json` format is enabled (without it:
error 403).

1. Open WebUI → Admin → Settings → Web Search: enabled, engine `searxng`, URL `http://searxng:8080/search`.
2. In a chat: **+ Integrations → Web Search** (to do again for each chat).

Test: `docker exec open-webui curl -s "http://searxng:8080/search?q=test&format=json" | head -c 300`.
The `ahmia` / `torch` (Tor engines) and `missing config file: limiter.toml` messages in `docker logs searxng` are harmless.

### Voice and documents (Kokoro, Tika)

- **Read aloud**: service `kokoro` (CPU version, no VRAM). Admin → Audio → Text-to-Speech: engine OpenAI, URL
  `http://kokoro:8880/v1`, key `not-needed` (any value), model `kokoro`, voice `af_bella`. Kokoro mostly has
  **English voices** (`af_*`, `am_*`, `bf_*`, `bm_*`), plus a few other languages (French: `ff_siwis`); see
  [docs/open-webui.md](docs/open-webui.md) §4.
- **Dictation**: microphone button, Open WebUI's local Whisper. In Admin → Audio → **Speech-to-Text**, the engine must
  stay the default (local Whisper): Kokoro only does synthesis, and setting it as STT gives a 404 error.
- **Documents**: service `tika` (PDF/Office extraction for RAG). Admin → Settings → Documents: engine Tika, URL
  `http://tika:9998`. If extraction fails, set "Tika Server Version" (3.x or 4.x) to match the server.
- Tests: `docker exec open-webui curl -s http://kokoro:8880/health` and `docker exec open-webui curl -s http://tika:9998/tika`.

## Monitoring (Prometheus + Grafana)

Independent project. Started by `./3-demarrer.sh`.

The "AI Lab" dashboard is loaded automatically: GPU utilisation and temperature, VRAM, power, CPU, RAM, disk. It only uses
the GPU exporter metrics that could be confirmed (utilisation, used VRAM, power, temperature). More detailed: Grafana →
Dashboards → Import, ID `14574`.

Limits: `node-exporter` runs in bridge networking (the **network** statistics shown are the container's); Ollama does not
expose Prometheus metrics as far as we know; the OpenClaw job is commented out in `monitoring/prometheus/prometheus.yml`
(not tested); if `gpu-exporter` does not start: `docker logs gpu-exporter`.

### Limiting GPU power (recommended)

An RTX 3090 draws up to 350 W. 300 W reduces heat and noise for a usually small loss of speed (measure it on your
machine). Accepted bounds: `nvidia-smi -q -d POWER`.

```bash
sudo nvidia-smi -pm 1 && sudo nvidia-smi -pl 300     # temporary: lost at reboot
```

**Permanent, in one command: `lab gpu-limit install 300`** (see `docs/performance.md` for the measurement that justifies
300 W on the reference machine). Manually: a systemd service that runs `nvidia-smi -pm 1` then `nvidia-smi -pl 300` at
boot (`/etc/systemd/system/gpu-power-limit.service`, type `oneshot`, `WantedBy=multi-user.target`), then
`sudo systemctl enable --now gpu-power-limit.service`. Check: `nvidia-smi --query-gpu=power.limit --format=csv`.

## Hermes Agent (Nous Research) — optional

Project `hermes/`, official image `nousresearch/hermes-agent`. Network `hermes-net` (internal): Hermes **only sees
Ollama** (plus Langfuse through `obs-net` if you install it), and has no Internet access
([docs/agent-isolation.md](docs/agent-isolation.md)). No Docker socket, no published port: it works inside its
container, with a single shared folder, `hermes/data/`.

```bash
docker exec ollama ollama list        # exact model name
./5-hermes.sh MODEL_NAME              # opens a conversation with Hermes
```

- **Files**: what you put in `hermes/data/workspace/` is seen by Hermes as `/opt/data/workspace/`. Always give it that
  path (not `hermes/...`, which is the path on your machine). It reads PDFs directly.
- **Required context**: 64,000 tokens minimum (see "Model and context" above).
- **Sub-agents**: Hermes can start them. With `OLLAMA_NUM_PARALLEL=1` (the default here), their requests run one after
  the other on the GPU: it works, without a speed gain. Raising this setting multiplies context memory and can overflow
  the VRAM.
- The container is disposable (`--rm`): only what is in `hermes/data/` is kept.
- **Closing the terminal stops the session** (container `hermes-session-…` removed), even if the SSH connection drops.
  For a session to survive a disconnection, start it in `tmux`. `lab doctor` reports a session running for more than
  12 h.
- **Development workflow** (git projects, review, merge by you): [docs/agent-development.md](docs/agent-development.md).
  **Access to a test machine** over SSH, admin scripts after your approval: [docs/hermes-ssh.md](docs/hermes-ssh.md).
- **Graphical interface** (optional): the Hermes Desktop app can drive the agent instead of the terminal. `lab gateway
  start` serves the dashboard on `127.0.0.1:9119` (reached from your PC through the SSH tunnel), on the same data and
  with the same isolation as a command-line session: [docs/hermes-desktop.md](docs/hermes-desktop.md).

## Langfuse (agent tracing) — optional

Langfuse records every model call: prompts, answers, duration, tokens, tools used by the agent. It uses the **official**
`docker-compose.yml` (cloned into `langfuse/app`) with an override that binds it to `127.0.0.1:3002` (3000 = Open WebUI,
9090 = Prometheus) and puts it on `obs-net`. Langfuse recommends: 4 cores, 16 GB of RAM, ~100 GB of disk. This Compose
installation has neither high availability nor backups of its own.

```bash
cd ai-stack && docker compose up -d && cd ..   # creates the obs-net network
./6-langfuse.sh                                # clones, generates the secrets, starts, shows account and keys
```

Account, password and API keys are created in advance and written to `langfuse/app/.env` (hidden).

- **Open WebUI**: Admin → Functions → new function (Langfuse filter, code at
  https://docs.openwebui.com/tutorials/integrations/monitoring/langfuse), then in its Valves: public key, secret key,
  host `http://langfuse-web:3000`. Enable it as "Global". Keep the Langfuse SDK at v3.
- **Hermes**: `./5-hermes.sh MODEL plugins install langfuse` (needs Internet: temporarily `lab isolation remove`, then
  `lab isolation apply`), then in `hermes/data/.env`: `HERMES_LANGFUSE_PUBLIC_KEY`, `HERMES_LANGFUSE_SECRET_KEY`,
  `HERMES_LANGFUSE_BASE_URL=http://langfuse-web:3000` (and `HERMES_LANGFUSE_CAPTURE=metadata` to send neither prompts nor
  answers). Not verified: the plugin should survive the container being closed; check with `plugins list` at the next
  start.

## Images (ComfyUI) — optional

Separate project `comfyui/`, **only start it when you need it** (it takes a lot of VRAM). **Community** image
(`ghcr.io/clsferguson/comfyui-docker`, MIT), pinned by digest in `comfyui/docker-compose.yml`; update procedure and
durable settings: [docs/image-generation.md](docs/image-generation.md).

```bash
./4-comfyui.sh          # unloads the Ollama models then starts ComfyUI
./4-comfyui.sh stop     # stops it and frees the VRAM
```

1. Put an image model (`.safetensors`) in `comfyui/data/models/checkpoints/`, run `./4-comfyui.sh` again.
2. In ComfyUI: Settings → "Dev Mode", load a workflow that works, File → **Export (API)** (JSON file).
3. Open WebUI → Admin → Settings → **Images**: engine **ComfyUI**, URL `http://comfyui:8188`, import the JSON, check the
   field mapping (prompt, model, size, steps, seed).
4. In a chat: **+ Integrations → Image**.

## Benchmark bench — optional

Project `bench/`: measurements with confidence intervals (speed, KV cache, context, parallelism, **performance loss
depending on the GPU power limit**). It starts its own test Ollama and temporarily stops the production one.

```bash
./7-bench.sh check
./7-bench.sh run quick-smoke --model qwen3.8:27b     # ~5 min
./7-bench.sh run power-sweep --model qwen3.8:27b     # power → tok/s, J/token, °C curve
```

HTML report in `bench/results/…/report.html`. Method and limits: `bench/README.md`.

## OpenClaw — optional

Prerequisite: `ai-stack` is running (it creates the `llm-net` network) and a model is downloaded.

```bash
./openclaw/install.sh
```

The script clones the official repository, adds an override (the gateway joins `llm-net`), runs the official installer,
then limits OpenClaw's ports to `127.0.0.1` and reapplies the agent firewall. Answers to give: provider **Ollama**, mode
**Local only**, URL `http://ollama:11434` (not `host.docker.internal`), the downloaded model. Interface:
http://127.0.0.1:18789/ with the `OPENCLAW_GATEWAY_TOKEN` from `~/openclaw/.env`.

Useful commands (from `~/openclaw`):

```bash
docker compose run --rm openclaw-cli dashboard --no-open     # show the URL again
docker compose run --rm openclaw-cli models list --provider ollama
docker compose logs -f openclaw-gateway
```

Update: `cd ~/openclaw && git pull && docker compose pull && docker compose up -d`.
**Important:** the official script calls `docker compose -f docker-compose.yml`, which ignores the network override.
After any recreation of the gateway (update, `up -d`), reattach it to Ollama:
`docker network connect llm-net $(docker compose -f docker-compose.yml ps -q openclaw-gateway)` (no effect if it is
already attached; `./openclaw/install.sh` does it too), then `lab isolation apply`.
Real installation, pitfalls, security (ports, allowed models and tools): [docs/openclaw.md](docs/openclaw.md).

## Storage (second SSD on /data) — optional

System on one disk, heavy data (Docker images, volumes including the Ollama models) on a second disk mounted on
`LAB_DATA_DIR` (`/data` by default). Reference machine: 480 GB NVMe + 4 TB SSD. Without a second disk, skip this section
and set `LAB_DATA_DIR` in `lab.conf`.

```bash
./8-stockage.sh status          # disks, /data, Docker root
./8-stockage.sh disk /dev/NAME  # ERASES this disk (name required, see "status"), ext4, mounted through fstab
./8-stockage.sh docker          # stops the containers, copies Docker to /data/docker, data-root + systemd guard
./3-demarrer.sh                 # then restart the services
```

The old folder stays in `/var/lib/docker.old` until you delete it. A disk alone is not a backup (an encrypted copy to
another medium is still needed).

## Stopping or shutting down the machine

You can simply shut down: Docker stops its containers cleanly, the data stays in the volumes, and the services come back
on their own at boot (except ComfyUI, and Hermes which is only started on demand). To stop everything cleanly before:

```bash
for d in ai-stack monitoring comfyui langfuse/app; do (cd $d 2>/dev/null && docker compose stop); done
(cd ~/openclaw 2>/dev/null && docker compose stop)
```

Restart: `./3-demarrer.sh` (or `lab start`), then `docker compose up -d` in `langfuse/app` and `~/openclaw` if installed.
**Never use `docker compose down -v`**: the `-v` option deletes the volumes (conversations, workflows, models).

## Security (read before giving tools to an agent)

Overview with diagrams (networks, ports, access, agents, remaining risks):
[docs/security-architecture.md](docs/security-architecture.md).

- **Agents without Internet**: Hermes and OpenClaw only reach Ollama (and Langfuse); the Internet, the local network and
  the machine itself are closed to them, except SSH to the test machines you allow: `lab isolation install`,
  [docs/agent-isolation.md](docs/agent-isolation.md).
- **Check the exposure**: `ss -tlnp | grep -vE '127\.0\.0\.1|\[::1\]|127\.0\.0\.53'` must only show SSH (22) and, if
  enabled, the remote desktop (3389). Docker bypasses UFW: a port published on `0.0.0.0` would be reachable from the
  network, which is why every port of the lab is bound to `127.0.0.1`.
- **Remote access**: SSH tunnels over the local network or a VPN (Tailscale, WireGuard…), never a port open to the
  Internet: [docs/remote-access.md](docs/remote-access.md).
- **Data**: do not mount your personal folders into an agent container. Only copy what it needs.
- **Accounts**: at first, no real mail or accounts connected. An agent that reads external content (web, mails,
  messages) can be manipulated by that content (prompt injection).
- **Secrets**: treat `ai-stack/.env`, `langfuse/app/.env` and `~/openclaw/.env` as credentials.
- **Plugins and functions** (Open WebUI, Hermes): they run code on your machine; read them before installing them.
- **Backups**: volumes `ollama_data`, `n8n_data`, `postgres_n8n_data`, `qdrant_data`, `open_webui_data`, `grafana_data`,
  the Langfuse volumes, and the folders `hermes/data`, `comfyui/data`, `~/.openclaw`. Not forgetting the `.env` files.

## Quick troubleshooting

| Symptom | Lead |
|---|---|
| `docker: command not found` | `./1-prerequis.sh` did not finish; run it again and read the end of the message |
| `apt`: "Release … is not valid yet" | The machine's clock is wrong: `sudo timedatectl set-ntp true` |
| `apt`: `dpkg` lock busy (`unattended-upgr`) | Automatic update running; wait: `pgrep -a unattended-upgr` |
| `could not select device driver "nvidia"` | NVIDIA Container Toolkit not configured: `./1-prerequis.sh` |
| `network llm-net / hermes-net / obs-net not found` | Start `ai-stack` first (`docker compose up -d`) |
| SearXNG looping: `settings.yml is a directory` | Docker created a fake folder: `docker compose stop searxng`, `sudo rm -r ai-stack/searxng/settings.yml`, `sudo chown "$USER": ai-stack/searxng`, copy the real file back, then `docker compose rm -sf searxng && docker compose up -d searxng` |
| Dictation: 404 on `/audio/transcriptions` | The STT engine points to Kokoro: set local Whisper back (Admin → Audio → STT) |
| Voice not found (`Voice "…" not found`) | Pick a voice from the list (`af_bella`…) in Admin → Audio |
| Hermes cannot find a file | Use the path seen by Hermes: `/opt/data/workspace/…` |
| Hermes refuses to start | Context < 64000: `OLLAMA_CONTEXT_LENGTH=65536`, then `docker compose up -d` |
| OpenClaw cannot reach Ollama | `docker network connect llm-net openclaw-openclaw-gateway-1`; `docker compose run --rm openclaw-cli doctor --json`; URL `http://ollama:11434` |
| Very slow answers | `docker exec ollama ollama ps`: the model spills over to the CPU |
| n8n: cookie/login refused over http | `N8N_SECURE_COOKIE=false` in `ai-stack/.env` |
| An agent reaches the Internet | `lab isolation test`, `lab doctor`: see [docs/agent-isolation.md](docs/agent-isolation.md) |
