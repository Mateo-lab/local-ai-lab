# Hermes Desktop graphical interface (`lab gateway`)

The [Hermes Desktop](https://github.com/NousResearch/Hermes) app gives Hermes a graphical interface instead of the
terminal conversation. The app runs on **your PC**; on the AI machine, Hermes is started in **remote gateway** mode: a
persistent `serve` container that exposes the dashboard on `127.0.0.1:9119`. The app connects to it through the SSH
tunnel you already use for the other interfaces.

It uses the **same data** as the command-line agent (`hermes/data/`): the app shows your existing sessions, memory,
skills and projects. Nothing is duplicated or lost — the command line and the interface are two ways into the same
agent.

> One at a time. The gateway and an interactive session (`./5-hermes.sh`, `lab dev`) share the same SQLite state
> (`hermes/data/state.db`). **Never run both at once.** `lab gateway start` refuses while a session is running, and
> `./5-hermes.sh` refuses while the gateway is running.

## In short

```bash
# One-time: set a dashboard password (see "Authentication" below), then:
lab gateway start            # starts the interface on 127.0.0.1:9119
lab gateway status           # running? does it answer?
lab gateway stop             # stops it (frees state.db for ./5-hermes.sh and lab dev)
```

On your PC: make sure the `9119` tunnel is open (`lab client` adds it to the `aibeast` SSH shortcut — regenerate and
reinstall the block, then reopen the tunnels), then in the Hermes Desktop app go to **Settings → Gateways → Remote
gateway** and enter `http://127.0.0.1:9119`.

## Prerequisites

1. Hermes has been started at least once, so `hermes/data/config.yaml` exists (`./5-hermes.sh MODEL`).
2. The agent firewall is active (`lab isolation status` → `active`). The gateway's isolation relies on it, exactly like
   any Hermes session. `lab gateway start` warns if it is off.
3. The Hermes Desktop app is installed on your PC (download from the project's official releases).

## Authentication (one time, required)

Bound on `0.0.0.0` (needed so Docker can publish the port), the dashboard **refuses to start without an authentication
provider** — it logs `Refusing to bind dashboard to 0.0.0.0 … no auth providers are registered`. Set a username and a
password hash in `hermes/data/config.yaml`.

Generate the hash **inside the image** (the password is typed at the prompt, so it never lands in your shell history and
a `!` in it causes no problem):

```bash
cd ~/Documents/ai-lab/hermes
docker run --rm -it --entrypoint python -w /opt/hermes \
  nousresearch/hermes-agent:stable \
  -c 'import getpass; from plugins.dashboard_auth.basic import hash_password; print(hash_password(getpass.getpass("Password: ")))'
```

Copy the printed hash, then add this block at the end of `hermes/data/config.yaml` (two-space indentation):

```yaml
dashboard:
  basic_auth:
    username: hermes
    password_hash: "<the hash printed above>"
```

The `password_hash` is not the password: only the hash is stored, and `hermes/data/` is excluded from git, so the
secret never leaves the machine. (Alternative: OAuth via `hermes dashboard register` — not covered here.)

## The tunnel

The dashboard is bound to `127.0.0.1` on the AI machine: it is **not** reachable from the local network. Your PC
reaches it over SSH, like every other interface.

- Permanent: `lab client` includes `LocalForward 127.0.0.1:9119 127.0.0.1:9119` in the generated block. Regenerate it,
  reinstall it in your PC's SSH config, then reopen the tunnels (`ssh -N aibeast`). The line is harmless when the gateway
  is stopped (it simply carries no traffic).
- One-off, without touching your config:

  ```bash
  ssh -N -L 127.0.0.1:9119:127.0.0.1:9119 aibeast
  ```

Then the app points at `http://127.0.0.1:9119` and shows the login page.

## How it is isolated

The gateway runs on the **same networks as an interactive Hermes session**: `hermes-net` (Ollama), `obs-net` (Langfuse
traces) and `hermes-sortie`. `hermes-sortie` is the only non-internal network — required to publish the port — and it is
**already filtered by `lab isolation`** (interface `br-hermes-out`): every outgoing connection is dropped except SSH to
the test machines in `lab.conf`. So the gateway gets the same confinement as any Hermes — no Internet, no local network —
**without any extra firewall rule**. The published port stays reachable because the tunnel's incoming connection and its
replies are allowed, exactly like OpenClaw's published interface (see [agent-isolation.md](agent-isolation.md)).

Measured on the reference machine, firewall active: the port answers on `127.0.0.1:9119` (HTTP 302 → `/login`), the
container cannot reach the Internet (`1.1.1.1:443` and a name both time out), and Ollama is reachable.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `lab gateway start` refuses: interactive session running | A `./5-hermes.sh` / `lab dev` session is open (shared `state.db`). Close it. |
| `lab gateway start` refuses: no `dashboard:` block | Set up authentication above. |
| `HTTP 000` from `curl 127.0.0.1:9119` | The container is still starting (wait a few seconds) or the port is not published — check `docker port hermes-gw`. |
| Log: `Refusing to bind dashboard to 0.0.0.0` | Authentication missing or malformed in `config.yaml`. |
| The app reaches the login page but rejects the credentials | Regenerate the hash (the password is checked against `password_hash`). |
| GPU busy / slow replies | One big model fills the 24 GB and Ollama serves one request at a time; the interface does not change that. |

## What is not verified

- The gateway and the login were tested with the Hermes Desktop app against image `nousresearch/hermes-agent:stable`
  (v0.22.0) on the reference machine. A future image may change the `serve` flags, the dashboard, the login flow or the
  `plugins.dashboard_auth.basic` module used to hash the password; re-check after `lab update`.
- The OAuth path (`hermes dashboard register`) was not tested; only `dashboard.basic_auth` was.
- The isolation of the gateway depends on `lab isolation` being active; with the firewall off, the gateway — like any
  Hermes on `hermes-sortie` — would have Internet access.
