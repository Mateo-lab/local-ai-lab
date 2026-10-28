# The `lab` command

A single command to drive everything. File: `lab` (at the root of the project).

## Installation
```bash
cd ~/Documents/ai-lab && ./lab install     # creates the link ~/.local/bin/lab
lab doctor
```
If `~/.local/bin` is not in your PATH, the command says so (line to add to `~/.bashrc`).

## Reference

| Command | Effect |
|---|---|
| `lab status` | All containers, GPU (state, watts, °C, VRAM), `/` and `/data` disks |
| `lab doctor` | Health check (see below). Non-zero exit code if there is a problem |
| `lab start [project]` | Starts everything in the order `ai-stack → monitoring → portail → alerting`, or a single project (also `comfyui`, `langfuse`) |
| `lab stop [project]` | Stops (`docker compose stop`): **deletes neither containers nor volumes** |
| `lab logs SERVICE [n]` | Live logs of a container (Ctrl-C to quit) |
| `lab urls` | Addresses of all the interfaces |
| `lab models` | Installed models and models loaded in VRAM |
| `lab task-model NAME` | See `open-webui.md` §1 |
| `lab bench [name] [...]` | Benchmark bench. Without a name: list. The model is the loaded one (otherwise the first installed); force it with `--model NAME` or `LAB_MODEL=NAME` |
| `lab gpu-limit status\|install [W]\|remove` | See `performance.md` §1 |
| `lab desktop on\|off\|status [--boot]` | Remote desktop on demand (`lab bureau` also works): see `remote-access.md` §9 |
| `lab isolation install\|apply\|status\|test\|remove\|uninstall` | Cuts the agents (Hermes, OpenClaw) off from the Internet, the local network and the machine: `agent-isolation.md` |
| `lab client [--print]` | Generates the PC's SSH configuration (`aibeast` shortcut, tunnels, remote desktop) from `lab.conf`: `remote-access.md` §5 |
| `lab backup init\|run\|list\|check\|restore\|schedule` | See `backups.md` |
| `lab config [list\|set MODEL NAME]` / `lab main-model` | Stored main model (see `docs/windows-shortcuts.md`) |
| `lab.conf` (optional, at the root of the project) | Machine-specific settings: `LAB_DATA_DIR`, `LAB_MODEL`, remote access `LAB_HOST`… (see `docs/configuration.md`) |
| `lab backup repo` | Prints the location of the backup repository (used by the off-machine copy from Windows) |
| `lab tmux update\|backup\|doctor` | Long action in a tmux session (survives an SSH disconnection) |
| `lab dev new\|list\|start\|review\|check\|merge\|setup\|ctx64` | Development with Hermes: `docs/agent-development.md` |
| `lab gateway start\|stop\|status` | Hermes Desktop graphical interface (remote gateway on `127.0.0.1:9119`): `docs/hermes-desktop.md` |
| `lab panel install\|token\|status\|logs\|uninstall` | Web button panel: `docs/web-panel.md` |
| `lab remote add\|show\|link\|list\|test\|remove` | Hermes SSH access to a test machine: `docs/hermes-ssh.md` |
| `lab mode agents [hermes\|openclaw]\|images\|normal\|status` | See "Agents mode" and "Images mode" below |
| `lab session list\|close [NAME\|--all]` | Open Hermes sessions (containers `hermes-session-…`): list, or close (without a name: the only one; several: name or `--all`). Hermes's memory and the project files are kept |
| `lab update [--no-backup]` / `lab rollback` | See below |

`ComfyUI`, `Hermes`, `Langfuse` and `OpenClaw` keep their scripts (`4-comfyui.sh`, `5-hermes.sh`, `6-langfuse.sh`,
`openclaw/install.sh`) for installation. `lab start comfyui|langfuse` only runs `docker compose up -d` in their folder,
once installed.

## Agents mode: free resources without losing observation

```bash
lab mode status     # current mode, free VRAM, loaded models, the 8 containers using the most RAM
lab mode agents     # only ONE agent active (Hermes by default); stops Open WebUI, n8n, Qdrant, SearXNG, ComfyUI, Kokoro, Tika, OpenClaw
lab mode agents openclaw   # same, but keeps OpenClaw instead of Hermes (refused while a Hermes session is open)
lab mode images     # unloads the Ollama models from VRAM and starts ComfyUI (see "Images mode")
lab mode normal     # restarts everything agents mode stopped (except ComfyUI) and OpenClaw if agents mode stopped it; from images mode, also stops ComfyUI
```
**What this mode does and does not do.** It leaves only what an agent needs plus what lets you watch the machine:
- **Kept**: Ollama, monitoring and alerts (Prometheus, Grafana, exporters, Alertmanager, ntfy, blackbox), the portal and **Langfuse**
  (it observes Hermes: stopping it would remove the trace of what the agent does).
- **Stopped**: Open WebUI, n8n (and its Postgres), Qdrant, SearXNG, Kokoro, Tika, ComfyUI.
- **One agent at a time**: `lab mode agents` (= `hermes`) also stops the OpenClaw gateway; `lab mode agents openclaw` starts
  OpenClaw and refuses to start Hermes sessions (`./5-hermes.sh`, `lab dev start`) until you switch back. Switching to
  `openclaw` is refused, without changing anything, while a Hermes session is open: close it first.
- Hermes starts on demand (a session = a container), OpenClaw is a permanent container: that is why "only one" means
  "the other is stopped or refused".

**What to expect from it.** The real constraint of a local agent is the **VRAM** (24 GB, of which ≈ 17 GB for the
27-billion-parameter model and its context cache). Only ComfyUI weighs on it. The other services run on the CPU: stopping
them saves RAM and CPU, **not VRAM**. The exact gain has not been measured: compare `lab mode status` before and after.
`lab doctor` warns if a second agent is active in this mode.

**Persistence.** The mode is stored in `.lab/mode` and the chosen agent in `.lab/agent`. While it is "agents", `lab start`,
`lab update` and `lab rollback` stop these services again (and OpenClaw in `hermes` mode), and `lab doctor` does not count
them as missing. After a reboot of the machine, Docker
does not restart a container stopped by hand (`unless-stopped`): the mode therefore stays consistent.

To change the list of stopped services: `AGENT_PAUSE` variable at the top of the `lab` script. The OpenClaw container name
can be changed with `OPENCLAW_CT` in `lab.conf` (default `openclaw-openclaw-gateway-1`).

Tests: `bash scripts/test-agents-mode.sh` (fake `docker`: stopped/started containers, guards, doctor). Not tested on the real
machine yet.

## Images mode: make room for ComfyUI

```bash
lab mode images     # unloads the Ollama models, starts ComfyUI, waits until the interface answers (http://127.0.0.1:8188)
lab mode normal     # stops ComfyUI (frees the VRAM for the Ollama models), restarts Kokoro and Tika
```
**Why.** Measured on the reference machine: `qwen3.8:27b` loaded takes ≈ 20 GB of VRAM out of 24; there is not enough
room left for SDXL (≈ 7 GB), which then falls back to RAM, slower. The two do not fit together: they have to alternate.

**What the mode does.** (1) `ollama stop` on every loaded model; (2) `docker compose up -d` for ComfyUI; (3) waits for
the interface to answer, up to 3 min (the very first start can take ≈ 10 min: waiting message, not an error);
(4) shows the VRAM before/after. Kokoro and Tika stay active (they do not use VRAM).

**Limit to know.** The mode does not *lock* Ollama: if Open WebUI, n8n or an agent sends a request to a model, it
reloads into VRAM (≈ 20 GB) and takes ComfyUI's place back. In images mode, avoid chatting with a model.
`lab doctor` no longer reports a GPU in P2 without a loaded model when ComfyUI is running (it was a false alarm during a
generation).

## Langfuse

Installed separately (`./6-langfuse.sh`, clone of the official repository into `langfuse/app`). Once installed,
`lab start`, `lab update` and `lab doctor` take it into account automatically (detection of
`langfuse/app/docker-compose.yml`). It starts about ten containers (web, worker, ClickHouse, Redis, MinIO, PostgreSQL):
measure its consumption with `lab mode status`. Connecting Hermes, pitfalls and reading API:
`docs/agents-langfuse.md`.

## `lab doctor`

Checks: Docker active; Docker root on `/data`; `/data` mounted; the 17 expected containers running; no `unhealthy`
container; GPU (limit, state, watts, temperature); remote desktop; disk usage (> 85 % = remark); model fully on the GPU;
age of the last backup; agent isolation.
`✗` = problem (exit code 1); `!` = remark (good to know, not blocking).

## Controlled updates

### Principle
The images use moving tags (`:latest`, `:main`). An update can therefore break something without warning. `lab update`
makes the operation **reversible** and **checked**:

1. encrypted backup (if configured; otherwise a warning. `--no-backup` to skip);
2. records, for each running container, `image reference → exact identifier` in `.lab/images-DATE.tsv`;
3. `docker compose pull` then `up -d` for each project;
4. waits 30 s, lists the images that changed, runs `lab doctor`.

If `doctor` reports a problem: `lab rollback`.

### Rollback
`lab rollback` re-tags the old images (`docker tag`) under their original name then restarts the projects.

> **Known limit (fixed, not tested on a real update):** during the first real update, the Langfuse containers (Docker
> project named `app`, not `langfuse`) were not recorded: MinIO was updated without being restorable by `lab rollback`.
> The script now finds the project by the folder name.

- Works **as long as the old images still exist** on disk. Do not run `docker image prune` or `docker system prune -a`
  before being sure of the update. Old images remain after a `pull` (untagged); they take space on `/data`.
- It does **not touch the data** (volumes). If the new version migrated a database to a newer format, the old image may
  refuse to read it: the backup must then be restored (`backups.md` §4). That is why step 1 makes an automatic backup.

### Suggested rhythm
No automatic updates. Once a month, or when a feature interests you: `lab update`, then a usage test (an Open WebUI
conversation, an n8n workflow) before deleting the old images (`docker image prune`, never `-a`).

## What is not verified

- `lab update` covers `ai-stack`, `monitoring`, `portail`, `alerting` and Langfuse (if installed). ComfyUI, Hermes and
  OpenClaw are updated with their own scripts/folders.
- `lab mode agents` and `lab mode images` are verified on the reference machine: Ollama unloaded, ComfyUI started, VRAM
  0.4 GB then 7.0 GB with SDXL, generation ≈ 15 s. Going back with `lab mode normal` from images mode is verified too:
  ComfyUI stopped, VRAM at 0.1 GB, `lab doctor` without remarks.
- Rollback assumes intact local images; it does not handle images referenced by digest (`@sha256`).
- `lab doctor` assumes the container names in the `EXPECTED` list at the top of the `lab` script; adapt it if you add
  or remove some.
