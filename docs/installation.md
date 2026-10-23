# Installing the lab on a new machine

This guide starts from a fresh Linux machine and goes all the way to access from your usual computer. Count 1 to 2
hours, mostly for the downloads (Docker images and models).

Vocabulary used everywhere:

- **the AI machine**: the Linux PC with the NVIDIA graphics card, where the whole lab runs. The scripts and the
  documentation also call it **AiBeast** (the name of the project's original machine).
- **your PC** (or **the client**): the computer you work from (Windows, macOS or Linux). It runs no model: it connects
  to the AI machine over SSH.

## 1. Prerequisites

### Hardware

| Item | Reasonable minimum | Project's reference machine |
|---|---|---|
| Graphics card | NVIDIA with 8 GB of VRAM or more | RTX 3090, 24 GB |
| RAM | 32 GB | 64 GB |
| Disk | 500 GB SSD (a single disk is enough) | 480 GB system + 4 TB data (`/data`) |
| Network | Ethernet recommended | Ethernet, access from outside through a VPN |

Only **NVIDIA** cards are supported by these scripts (proprietary driver + NVIDIA Container Toolkit).

**Which model size for your card?** Order of magnitude, for a model quantised to 4 bits (a common format in Ollama):
about 0.6 GB of VRAM per billion parameters, plus 1 to 4 GB for the context. Check it afterwards with
`docker exec ollama ollama ps`: the PROCESSOR column must show `100% GPU`.

| VRAM | Target model size (4 bits) | Starting context (`OLLAMA_CONTEXT_LENGTH`) |
|---|---|---|
| 8 GB | 7 to 8 billion parameters | 8192 |
| 12 to 16 GB | 12 to 14 billion | 16384 |
| 24 GB | 27 to 32 billion | 32768 (65536 possible with a `q8_0` KV cache, measured on the 3090) |

These numbers are indicative: only the 24 GB line was measured on the reference machine (`docs/performance.md`). The
Hermes agents require a 64,000-token context, which in practice needs 24 GB.

### Software

- **Ubuntu** (24.04 or newer) or Debian, or an Ubuntu derivative (Mint, Pop!_OS). The reference machine runs Ubuntu
  26.04. The `1-prerequis.sh` script installs Docker and the NVIDIA Container Toolkit from the official repositories; it
  does not handle Fedora, Arch, etc.
- **The NVIDIA driver already installed and active**: `nvidia-smi` must show your card. On Ubuntu:
  `sudo ubuntu-drivers install`, then reboot.
- **A normal user account** with `sudo` rights. Never run the lab's scripts with `sudo` in front.
- **git**: `sudo apt install git`.

## 2. Getting the project

On the AI machine:

```bash
mkdir -p ~/Documents && cd ~/Documents
git clone https://github.com/Mateo-lab/local-ai-lab.git ai-lab
cd ai-lab
```

(Or the address of your copy of the repository, if you made one.) The folder can be elsewhere; the documentation
assumes `~/Documents/ai-lab`.

## 3. Configuring the installation: `lab.conf`

```bash
cp lab.conf.example lab.conf
nano lab.conf
```

This is **the only file to adapt**. It contains no secret and is never versioned. Every line is commented in the file;
full details in [configuration.md](configuration.md). The settings to look at:

| Setting | When to change it |
|---|---|
| `LAB_DATA_DIR` | You do **not** have a second disk mounted on `/data`: set an existing folder on the system disk, for example `/srv/ai-lab` (created with `sudo mkdir -p /srv/ai-lab && sudo chown "$USER": /srv/ai-lab`) |
| `LAB_MODEL` | To set the main model (otherwise `lab` takes the largest installed model) |
| `LAB_HOST` | **Required for remote access**: the address your PC will use to reach the AI machine (see step 8) |
| `LAB_USER`, `LAB_SSH_PORT`, `LAB_SSH_KEY`, `LAB_RDP_LOCAL_PORT` | Only if your values differ from the defaults shown |

## 4. Installing Docker and the NVIDIA toolkit

```bash
./1-prerequis.sh
sudo reboot
```

After the reboot: `docker run --rm --gpus all ubuntu nvidia-smi` must show your card.

## 5. Creating the secrets and starting the core of the lab

```bash
cd ~/Documents/ai-lab
./2-secrets.sh                  # creates the .env files with random passwords (never overwrites anything)
./3-demarrer.sh MODEL_NAME      # starts ai-stack and monitoring, and downloads this model
./lab install                   # creates the "lab" command (link in ~/.local/bin)
lab start                       # also starts the portal and the alerts
lab doctor                      # full health check
```

- `MODEL_NAME`: a name from the Ollama library suited to your VRAM (table in §1). Without an argument, `3-demarrer.sh`
  uses `LAB_MODEL` from `lab.conf`, otherwise downloads nothing.
- Then adjust the context in `ai-stack/.env` (`OLLAMA_CONTEXT_LENGTH`, table in §1), then `lab start ai-stack`.
- `lab doctor` must finish without ✗. A `!` is a remark (for example "remote desktop active").

The numbered scripts keep their original names (`prerequis` = prerequisites, `secrets`, `demarrer` = start,
`stockage` = storage).

## 6. Second disk (optional)

If you have an **empty** second disk for the data:

```bash
./8-stockage.sh status    # list the disks: find the right name (/dev/nvme1n1, /dev/sdb…)
./8-stockage.sh disk /dev/DISK_NAME    # ERASES this disk, formats it and mounts it on LAB_DATA_DIR
./8-stockage.sh docker    # moves Docker's data to this disk
./3-demarrer.sh
```

`disk` **erases the whole disk given**: check the name three times. Without a second disk, skip this step and set
`LAB_DATA_DIR` (§3).

## 7. Optional modules

To install when you need them, in any order:

| Module | Command | Documentation |
|---|---|---|
| Image generation (ComfyUI) | `lab mode images` | [image-generation.md](image-generation.md) |
| Hermes agent | `./5-hermes.sh MODEL_NAME` | [agent-development.md](agent-development.md) |
| Agent tracing (Langfuse) | `./6-langfuse.sh` | [agents-langfuse.md](agents-langfuse.md) |
| Benchmark bench | `./7-bench.sh check` | `bench/README.md` |
| Encrypted backups | `lab backup init` then `lab backup schedule` | [backups.md](backups.md) |
| GPU power limit | `lab gpu-limit install 300` (value to adapt to your card) | [performance.md](performance.md) |
| Gmail sorting (n8n) | see the doc | [n8n-gmail.md](n8n-gmail.md) |
| OpenClaw | `./openclaw/install.sh` | [openclaw.md](openclaw.md) |

**Before using Hermes or OpenClaw**, cut them off from the Internet: `lab isolation install` then `lab isolation test`
([agent-isolation.md](agent-isolation.md)).

**At least set up the backups**: `lab backup init` shows a password to keep **off the machine** (password manager).

## 8. Access from your PC

Everything is explained step by step in [remote-access.md](remote-access.md). In short:

1. On the AI machine: `sudo apt install openssh-server`, then fill in `LAB_HOST` in `lab.conf`.
2. On the AI machine: `lab client` generates your PC's SSH configuration and shows the steps to follow.
3. On your PC: create an SSH key, copy it to the AI machine, paste the generated configuration.
4. On your PC: `ssh aibeast` must answer without a password; `ssh -N aibeast` opens the tunnels, then
   http://127.0.0.1:3010 shows the portal.
5. Only then: forbid SSH login by password (hardening).

On Windows, the project's `windows/` folder contains shortcuts to double-click (button console, tunnels, deployment,
backup copy): [windows-shortcuts.md](windows-shortcuts.md).

## 9. Checking network exposure

```bash
ss -tlnp | grep -vE '127\.0\.0\.1|\[::1\]|127\.0\.0\.53'
```

Only **SSH (22)** and, if enabled, the **remote desktop (3389)** may appear. All the lab's interfaces listen on
`127.0.0.1` and are only reachable through the SSH tunnels. OpenClaw's official compose publishes its ports on all
interfaces; `./openclaw/install.sh` binds them to `127.0.0.1` (see [openclaw.md](openclaw.md), Security section).

## 10. Keeping up to date

| I want to | Command |
|---|---|
| Update the Docker images (with a backup) | `lab update` (rollback: `lab rollback`) |
| Get a new version of the lab | `cd ~/Documents/ai-lab && git pull` then `./2-secrets.sh` (fills in new variables) and `lab start` |
| Check after a reboot | `lab doctor` |

ComfyUI is pinned to a precise version of its image: it is updated by hand ([image-generation.md](image-generation.md),
"Durable installation").

## What is not verified

- A full installation on a machine other than the reference machine (RTX 3090, Ubuntu 26.04) has never been done: this
  guide is written from the scripts and the original installation.
- The table of model sizes per amount of VRAM is indicative, except the 24 GB line.
- `lab doctor` on a single-disk machine (`LAB_DATA_DIR` on the system disk): the check was adapted, not tested on a real
  machine.
- `8-stockage.sh disk` has only been used on the reference machine.
