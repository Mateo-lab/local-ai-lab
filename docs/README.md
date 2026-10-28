# Documentation

AiBeast = the AI machine (the name of the project's original machine). Measurements and lessons learned come from this
reference machine: RTX 3090 24 GB, 64 GB of RAM, Ubuntu 26.04.

| Document | What it is for |
|---|---|
| [installation.md](installation.md) | **Start here**: install the lab on a new machine, from scratch to access from your PC |
| [remote-access.md](remote-access.md) | Key-based SSH, PC configuration (`lab client`), tunnels, remote desktop (RDP), startup, recovery |
| [lab.md](lab.md) | The `lab` command: reference, updates, rollback |
| [configuration.md](configuration.md) | `lab.conf`: machine-specific settings (data disk, model, remote access), separation of code / configuration / secrets |
| [security-architecture.md](security-architecture.md) | **Overview**: networks, ports, access, agent confinement, protections and remaining risks, with diagrams |
| [agent-isolation.md](agent-isolation.md) | Agents without Internet: internal networks, firewall (`lab isolation`), SSH exceptions, test machine, verification |
| [portal.md](portal.md) | Single home page (http://127.0.0.1:3010), Windows tunnels, adding a service |
| [open-webui.md](open-webui.md) | Task model, presets, settings, state of the voice features |
| [performance.md](performance.md) | GPU power limit, Ollama settings, measurement procedure |
| [understanding-benchmarks.md](understanding-benchmarks.md) | Why test power, context, KV cache…, how to read a report, glossary |
| [remote-desktop-gpu.md](remote-desktop-gpu.md) | Analysis: the remote desktop costs ≈ 100 W |
| [alerts.md](alerts.md) | Prometheus → Alertmanager → ntfy: rules, test, response |
| [backups.md](backups.md) | Encrypted backups (restic) and restore |
| [windows-shortcuts.md](windows-shortcuts.md) | Double-click on your PC: image mode, health, update, Hermes, SSH config, test machine tools; default model (`lab config`) |
| [web-panel.md](web-panel.md) | Button page (modes, health, update, backup, Hermes review) through the SSH tunnel (`lab panel`) |
| [hermes-ssh.md](hermes-ssh.md) | Give Hermes limited SSH access to a test machine (`lab remote`), admin scripts after approval |
| [agent-development.md](agent-development.md) | Developing with Hermes: git projects, code → test → review loop, merge by you (`lab dev`) |
| [hermes-desktop.md](hermes-desktop.md) | Hermes Desktop graphical interface: remote gateway on `127.0.0.1:9119`, authentication, tunnel, isolation (`lab gateway`) |
| [openclaw.md](openclaw.md) | OpenClaw: installation, pitfalls (network, dummy key, model, 64k context), security, update |
| [agents-langfuse.md](agents-langfuse.md) | Langfuse, connecting Hermes, agents mode, ComfyUI (first start), pitfalls |
| [image-generation.md](image-generation.md) | Images with Qwen-Image-2.1 in ComfyUI: installation, settings, measurements, examples, pitfalls |
| [n8n-gmail.md](n8n-gmail.md) | Sorting Gmail messages with the local model in n8n, old messages, validated trash (workflows in `n8n/`) |

Documentation at the root: `README.md` (overview, quick start), `bench/README.md` (benchmark bench).

Convention: every document ends with **"What is not verified"**. What comes before that section was measured on the
reference machine or checked; what is in it was not.

Commands, menu names and messages are quoted exactly as the tools display them; a few machine-level names created
before the translation keep their original French spelling (for example the Docker network `hermes-sortie` or the
folder `C:\ProgramData\hermes-admin\approuves`), because renaming them would break existing installations.
