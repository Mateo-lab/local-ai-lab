# Agents and Langfuse

Langfuse records what the agents do: every conversation turn, every model call (duration, tokens), every tool used.
Everything stays on AiBeast (`http://127.0.0.1:3002`).

Verified result on the reference machine: **Hermes → Langfuse works** (2 traces, 4 observations after a conversation).
OpenClaw is not connected (see §6).

## 1. Installing Langfuse

```bash
cd ~/Documents/ai-lab
./6-langfuse.sh
```
The script clones the official repository into `langfuse/app`, generates the secrets (`langfuse/app/.env`), starts ~6
services (web, worker, ClickHouse, Redis, MinIO, PostgreSQL) and waits until Langfuse answers.
The override `langfuse/docker-compose.override.yml` (copied into `langfuse/app/`):
- binds the interface to `127.0.0.1:3002` and MinIO to `127.0.0.1:9092/9091` (the official compose publishes on all
  interfaces);
- joins Langfuse to the `obs-net` network (shared with Open WebUI and Hermes);
- sets `HOSTNAME=0.0.0.0` for `langfuse-web`: without it, Next.js only listens on the container's first address, and
  the portal (health probe) and the agents, which go through `obs-net`, get "Connection refused".

Health: `docker exec homepage wget -qO- http://langfuse-web:3000/api/public/health` → `{"status":"OK",...}`.

## 2. Connecting Hermes

1. Langfuse: create an organisation and a `hermes` project, then Settings → API Keys → Create (public key `pk-lf-…`,
   secret key `sk-lf-…`, shown only once).
2. Write the variables into `hermes/data/.env` (file read by Hermes, included in the encrypted backup):
   ```
   HERMES_LANGFUSE_PUBLIC_KEY=pk-lf-…
   HERMES_LANGFUSE_SECRET_KEY=sk-lf-…
   HERMES_LANGFUSE_BASE_URL=http://langfuse-web:3000
   HERMES_LANGFUSE_ENV=local
   ```
   Once each: the plugin installer already writes these lines; do not add them a second time.
3. Install the plugin: `cd hermes && docker compose run --rm hermes plugins install langfuse`
   (in the tested version, `plugins enable observability/langfuse` answers "Langfuse moved out of core": it is a plugin
   from the official catalogue, version 2.0.0). The installation needs the Internet: `lab isolation remove` first, then
   `lab isolation apply` afterwards.
4. Check: `docker compose run --rm hermes plugins list --plain --no-bundled | grep -i langfuse` → `enabled`.
5. Test: `./5-hermes.sh MODEL chat`, write a message, wait for the answer, `/exit`, wait ~10 s.
   In Langfuse (project `hermes`): a "Hermes turn" trace with the model call.

Privacy: by default the plugin sends the content of the exchanges with secrets masked (`sanitized`).
`HERMES_LANGFUSE_CAPTURE=metadata` only sends durations, tokens and tool names.
`HERMES_LANGFUSE_DEBUG=true` is only useful for diagnosis: remove it afterwards.

## 3. What cost time (to avoid)

| Symptom | Cause | Remedy |
|---|---|---|
| No trace, no visible error | The plugin fails silently (wrong keys or address) | Logs: `hermes/data/logs/errors.log` (**timestamps in UTC**) |
| `Failed to resolve 'langfuse-web'` | `hermes/docker-compose.yml` without `obs-net` (copy older than its addition) | Add `- obs-net` to the service's networks **and** declare `obs-net: {external: true, name: obs-net}` at the bottom. Do not overwrite the file if you added other volumes (e.g. `./workspace:/workspace`) |
| `Input is not a terminal`, mixed-up input | `./5-hermes.sh … chat \| tee file`: Hermes needs a real terminal | Never redirect or go through `tee`; read the logs in `hermes/data/logs/` |
| `HTTP 404 … Langfuse v4 events_only mode` on `/api/public/traces` | Langfuse v4 removed this old endpoint | Use `GET /api/public/v2/observations?fromStartTime=…&limit=10` (basic auth public key:secret key). With some clients, possible delay of 15 min |
| `docker compose run` stuck on `Creating` after Ctrl+C / Ctrl+Z | Orphan `hermes-hermes-run-*` containers | `docker ps -aq --filter name=hermes-hermes-run \| xargs -r docker rm -f` |

Checking without the interface (the keys are never displayed):
```bash
cd ~/Documents/ai-lab/hermes
set -a; . ./data/.env; set +a
curl -s -G -u "$HERMES_LANGFUSE_PUBLIC_KEY:$HERMES_LANGFUSE_SECRET_KEY" \
  "http://127.0.0.1:3002/api/public/v2/observations" \
  --data-urlencode "fromStartTime=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)" --data-urlencode "limit=10"
unset HERMES_LANGFUSE_PUBLIC_KEY HERMES_LANGFUSE_SECRET_KEY HERMES_LANGFUSE_BASE_URL HERMES_LANGFUSE_ENV
```

## 4. Agents mode (`lab mode agents`)

Frees VRAM and RAM for the agents: stops ComfyUI, Kokoro and Tika. Ollama, Open WebUI, n8n, Qdrant, SearXNG, monitoring
and **Langfuse** stay active. Back: `lab mode normal` (does not restart ComfyUI: `lab start comfyui`). Details:
`docs/lab.md`.

## 5. ComfyUI: first start

- The image is ~8 GB. If the SSH session may drop during the download, start it in the background:
  `nohup ./lab start comfyui > ~/comfyui-start.log 2>&1 &`.
- First start: the container runs `chown -R` on the whole Python library. Heavy disk load, CPU at 0 %, **several
  minutes without a message** (observed: ~6 min). The interface (`http://127.0.0.1:8188`) answers afterwards; do not
  restart the container during this step. It happens again if the container is recreated (`lab update`).
- Models: `comfyui/data/models/checkpoints/`. Verified example: SDXL base 1.0 (6.9 GB) downloaded with
  `nohup wget -c -O sd_xl_base_1.0.safetensors https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors`.
  Not backed up (they can be downloaded again).

## 5a. Sharing the VRAM: Ollama versus ComfyUI (measured on the reference machine)

| Situation | VRAM used |
|---|---|
| `qwen3.8:27b` loaded (17 GB model, 65,536 context) + ComfyUI on | 20.8 GB / 24 GB |
| After `lab mode agents` (ComfyUI, Kokoro, Tika stopped) | 20.2 GB |
| After `lab mode images` (Ollama model unloaded, ComfyUI started, SDXL not loaded yet) | 0.4 GB |
| SDXL base 1.0 loaded in ComfyUI after a generation (images mode) | 7.0 GB |

The language model alone takes ~20 GB: SDXL (~7 GB) does not fit next to it and ComfyUI falls back to offloading to RAM
(slower; its RAM went up to 5.3 GB). The two uses therefore have to alternate: the Ollama model unloads by itself after
its idle delay (`UNTIL` column of `ollama ps`), or by hand with `docker exec ollama ollama stop MODEL_NAME`.
`lab mode images` automates this switch (see `docs/lab.md`).
Measured with `lab mode images`: ComfyUI starts in a few seconds (interface ready after ~25 s), VRAM at 0.4 GB before
the first generation, **SDXL generation in ≈ 15 s**, 7.0 GB of VRAM once the model is loaded. SDXL (7 GB) +
`qwen3.8:27b` (~20 GB) = ~27 GB > 24 GB: alternating is necessary.
The generation time *before* images mode (Ollama model loaded, ComfyUI falling back to RAM) was not timed: no numeric
comparison.

## 6. OpenClaw

Not connected. OpenClaw is deliberately isolated on `llm-net`, outside `obs-net`. It has a tracing plugin
(`diagnostics-otel`, OpenTelemetry protocol) that could target Langfuse (`/api/public/otel`), but that would require
joining it to `obs-net` and therefore loosening its isolation. A decision to make explicitly; nothing was done.

## 7. Backing up Langfuse

`lab backup run` backs up Langfuse's PostgreSQL database (accounts, projects, API keys, prompts) and its `.env`.
The container is found through the folder of its compose file (`langfuse/app`), not through the project name (Docker
names it `app`). **Not backed up**: ClickHouse (the traces themselves) and MinIO.

## What is not verified

- `lab mode agents`: tested with ComfyUI on and `qwen3.8:27b` loaded in Ollama. ComfyUI, Kokoro and Tika stop and come
  back; the VRAM goes from 20.8 to 20.2 GB (only 0.6 GB freed). Freeing a **fully loaded** image model is not measured.
- The exact content of a trace (level of detail of the `sanitized` mode) was not reviewed in the interface.
- Connecting OpenClaw, and n8n or Open WebUI as trace sources: not done.
- An update of the Hermes image (`:stable`) may change the plugin; test it again after `lab update`.
- Restoring the Langfuse database: tested (snapshot restored into `~/restore-test`, `langfuse.sql` loaded into a
  throwaway PostgreSQL with the same image: exit code 0, 1 user, 2 projects, 2 API keys). Not tested: actually putting it
  back into service (re-injecting the database into Langfuse) nor restoring ClickHouse (not backed up).
