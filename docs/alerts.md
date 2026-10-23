# Alerts: be warned before you notice the failure

Project: `alerting/` (started by `lab start`). Full chain:

```
blackbox-exporter ──(HTTP probes)──┐
node-exporter / gpu-exporter ──────┼──> Prometheus ──(rules)──> Alertmanager ──> alertmanager-ntfy ──> ntfy ──> browser / phone
                                   │    monitoring/prometheus/rules/alerts.yml
```

## 1. What is watched

| Alert | Condition | Duration | Severity |
|---|---|---|---|
| `ServiceUnreachable` | an HTTP probe fails (Open WebUI, n8n, Qdrant, Ollama, SearXNG, Kokoro, Tika, Grafana) | 3 min | critical |
| `ExporterUnreachable` | Prometheus no longer receives node-exporter or gpu-exporter | 2 min | warning |
| `DataDiskAlmostFull` | any ext4/xfs/btrfs disk except `/` (on the reference machine: `/data`) > 85 % | 10 min | warning |
| `SystemDiskAlmostFull` | `/` > 85 % | 10 min | warning |
| `RamAlmostFull` | RAM > 92 % | 10 min | warning |
| `GpuTooHot` | GPU > 85 °C | 5 min | critical |
| `GpuStuckInP2AtIdle` | P-state < 8 and utilisation < 5 % | 30 min | warning |

The last rule detects a problem seen on the reference machine (GPU at ≈ 124 W while doing nothing, see
`remote-desktop-gpu.md`). The thresholds are reasonable choices, not measurements: adjust them in
`monitoring/prometheus/rules/alerts.yml` (then `docker restart prometheus`).

Not watched: Langfuse, ComfyUI, Hermes (no probe added; ComfyUI and Hermes are off by default, an alert would be a
permanent false positive). To add a probe: one line in `targets` of the `probes` job in
`monitoring/prometheus/prometheus.yml`.

## 2. Start

```bash
lab start                 # starts everything, in order (ai-stack, monitoring, portail, alerting)
docker restart prometheus # once, if monitoring was already running: it reloads the rules
```

Checks:
1. `http://127.0.0.1:9090/rules`: the three groups (services, machine, gpu) must appear.
2. `http://127.0.0.1:9090/targets`: jobs `probes` and `blackbox` `UP`.
3. `http://127.0.0.1:9093`: Alertmanager answers.

## 3. Receiving notifications

The ntfy "topic" is `aibeast-alertes` (`alerting/alertmanager-ntfy/config.yml`). The name is kept as is so that existing
subscriptions keep working.

- **On the Windows PC** (tunnels open): open `http://127.0.0.1:2586/aibeast-alertes`, click the bell icon to allow
  browser notifications.
- **Test without waiting for a failure** (on AiBeast):
  `curl -d "alert test" http://127.0.0.1:2586/aibeast-alertes`: the message must appear. This tests ntfy alone.
- **Test of the full chain**: `docker stop searxng`, wait ≈ 4 min (3 min duration + 30 s grouping) → notification
  "searxng:8080 is not answering"; `docker start searxng` → notification that it is back to normal.
- **On a phone**: the ntfy app can subscribe to a self-hosted server, but the port is bound to `127.0.0.1`. For a phone
  connected to the VPN to reach it, set in `alerting/.env` `NTFY_BIND=<AiBeast's IP on the VPN>` and
  `NTFY_BASE_URL=http://<that IP>:2586`, and `NTFY_AUTH_DEFAULT_ACCESS=deny-all` (then create an account with
  `docker exec -it ntfy ntfy user add --role=admin YOUR_NAME`). On Android, subscribing to an `http` server works; on
  iOS notifications go through the ntfy.sh service, which needs extra configuration (`upstream-base-url`) not done here.

## 4. What to do when an alert arrives

| Alert | First move |
|---|---|
| `ServiceUnreachable` | `lab status`, then `lab logs <service>`; `docker restart <service>` |
| `DataDiskAlmostFull` | `lab doctor`, `docker system df`, old results in `bench/results/` |
| `SystemDiskAlmostFull` | `sudo journalctl --vacuum-size=200M`, `sudo apt clean` |
| `GpuTooHot` | airflow, dust; `lab gpu-limit install 300` |
| `GpuStuckInP2AtIdle` | `nvidia-smi`; `lab desktop off` from an SSH session |
| `ExporterUnreachable` | `docker ps`; `lab logs gpu-exporter` |

## 5. What is not verified

- **Verified on the reference machine**: the full chain (probe → `ServiceUnreachable` rule → Alertmanager → bridge →
  ntfy → browser), including the "Resolved" message when searxng restarts. The message arrives with the expected title,
  text and labels.
- **Not verified**: the six other rules (disks, RAM, temperature, GPU stuck in P2, exporters) have never fired; their
  syntax is checked, not their real threshold nor the existence of every metric.
- Bridge `ghcr.io/alexbakker/alertmanager-ntfy`: the image, the command (`--configs`), port 8000 and the `/hook` URL are
  **verified** (alert received). A first configuration that was too short (only `topic`) crashed the bridge
  (`nil pointer dereference` in `forwardAlert`, answer 500 to Alertmanager): `priority`, `tags` and `templates` must also
  be defined, as in the provided file. Plan B if the bridge causes trouble: a webhook receiver of your choice (n8n can
  receive one and call ntfy).
- The `aibeast-alertes` topic contains a hyphen; the bridge accepts an expression for `topic`. If messages do not arrive
  under that name, try a topic without a hyphen (to change in the reading URL too).
- The `nvidia_smi_*` metric names: `nvidia_smi_pstate` (number from 0 to 15) and `nvidia_smi_utilization_gpu_ratio`
  (0 to 1) are assumed; the portal tile uses them too. Check them at `http://127.0.0.1:9090/graph`. If one is missing,
  the rule never fires, without an error.
- Disks are seen by node-exporter through `/:/host:ro,rslave`; a data disk absent from `node_filesystem_size_bytes`
  (a file system other than ext4/xfs/btrfs, for example) is not watched.
- The probes count a 401/403 code as "alive".
