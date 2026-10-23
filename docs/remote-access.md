# Remote access: SSH, tunnels and remote desktop

Goal: use every interface of the lab from your PC, at home as well as outside, **without exposing anything to the
Internet**, without ever locking yourself out, and without paying ≈ 100 W more continuously for a remote desktop.

## 1. The principle

```
 YOUR PC                                   NETWORK                        AI MACHINE (AiBeast)
 browser    → 127.0.0.1:3010 ─┐
 browser    → 127.0.0.1:3000 ─┤
 RDP client → 127.0.0.1:13389 ┤   a single encrypted channel: ┌→ 127.0.0.1:3010  portal
 terminal   → ssh aibeast   ──┴── SSH (port 22) ─────────────→ sshd ─┼→ 127.0.0.1:3000  Open WebUI
                                  local network, VPN or Tailscale    ├→ …                (every interface)
                                                                     └→ 127.0.0.1:3389  remote desktop (RDP)
```

- On the AI machine, **every interface only listens on `127.0.0.1`**: nobody on the network can reach them directly,
  not even you.
- **SSH is the only way in.** Once connected, SSH carries "tunnels": your PC listens on its own ports (`127.0.0.1:3000`
  on the PC) and forwards each connection to the same port of the AI machine. In your browser, you therefore type
  `http://127.0.0.1:3000` as if you were sitting in front of the AI machine.
- The **remote desktop** (seeing the AI machine's graphical screen) goes through the same channel: it is never opened
  directly on the network.

| Path | What it is for | Cost | Depends on |
|---|---|---|---|
| **Key-based SSH** | Administration (terminal, `lab`), and carrying everything else | none | network + key |
| **SSH tunnels** | Opening the web interfaces in the PC's browser | none | SSH |
| **Remote desktop** (GNOME Remote Desktop, RDP) | Seeing and using the AI machine's screen | **≈ 100 W** during a session (GPU kept in P2, measured) | SSH + service enabled |

SSH is also the **fallback** path: if everything else is broken, SSH lets you repair it. Never make it unusable (see §6
before hardening).

## 2. How your PC reaches the AI machine (`LAB_HOST`)

Choose **one** way, then write the matching address in `lab.conf` (`LAB_HOST=…`):

| Situation | Address to put in `LAB_HOST` | Notes |
|---|---|---|
| Same local network (home) | Local IP of the AI machine: `hostname -I` on the AI machine | Reserve this IP in your router (fixed DHCP lease), otherwise it may change |
| Existing VPN (router, company) | IP of the AI machine as seen through the VPN | This is the reference machine's case |
| Tailscale (mesh VPN, free for personal use) | Tailscale name or IP of the AI machine (`tailscale ip -4`) | To install on the AI machine **and** on the PC; no port to open on the router |
| WireGuard you manage | IP of the AI machine inside the WireGuard tunnel | Requires opening a UDP port on the router for WireGuard, not for SSH |

**Never open port 22 (SSH) or 3389 (remote desktop) of your router to the Internet.** Go through the local network or a
VPN.

## 3. Installing the SSH server on the AI machine

```bash
sudo apt install openssh-server
systemctl status ssh          # must show "active (running)"
```

At this stage, **password** login is still allowed: it is used only once, to copy your key.

## 4. Your PC's SSH key

An SSH key is a pair of files created **on your PC**:
- the **private** key (`id_ed25519`) stays on the PC, is never copied, never sent;
- the **public** key (`id_ed25519.pub`) is copied to the AI machine, into `~/.ssh/authorized_keys`.

### Windows (PowerShell)

The SSH client is included in Windows 10 and 11. `ssh-copy-id` does not exist on Windows; the 2nd command does the same
thing. Replace `USER` and `ADDRESS` (or copy the ready-made command shown by `lab client`).

```powershell
# 1. Create the key (Enter for the default location; a passphrase is recommended)
ssh-keygen -t ed25519

# 2. Copy the PUBLIC key to the AI machine (the Linux account password is asked this time)
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh USER@ADDRESS "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# 3. Test: must connect WITHOUT asking for the account password
ssh USER@ADDRESS
```

### macOS / Linux (Terminal)

```bash
ssh-keygen -t ed25519
ssh-copy-id USER@ADDRESS
ssh USER@ADDRESS        # must connect without the account password
```

If you set a passphrase, it is asked at every connection. To type it only once per session: SSH agent (Windows: the
"OpenSSH Authentication Agent" service then `ssh-add`; macOS: `ssh-add --apple-use-keychain`).

## 5. The PC's SSH configuration (`lab client`)

So that you do not retype the address and the list of tunnels, your PC keeps a **shortcut** named `aibeast` in its SSH
configuration file. Every script in `windows/` uses that name.

On the AI machine:

```bash
lab client
```

The command reads `lab.conf` (`LAB_HOST`, `LAB_USER`, `LAB_SSH_PORT`, `LAB_SSH_KEY`, `LAB_RDP_LOCAL_PORT`), prints the
configuration block, also writes it to `windows/ssh_config_aibeast.txt` (a file specific to your machine, ignored by
git), and reminds you of the steps. Example block: `windows/ssh_config_aibeast.example`.

**On Windows, the simplest**: copy `windows/ssh_config_aibeast.txt` into the PC's `windows\` folder (for example
`scp aibeast:Documents/ai-lab/windows/ssh_config_aibeast.txt windows\` if the old shortcut still works), then
double-click `windows\outils\Installer-config-SSH.bat`: it backs up your configuration, replaces the old `aibeast` block
(or adds it) without touching the others. Otherwise, by hand:

On your PC, **add this block at the end** of the SSH configuration file (create it if it does not exist, no extension):
- Windows: `C:\Users\YOUR_NAME\.ssh\config` (in PowerShell: `notepad $env:USERPROFILE\.ssh\config`);
- macOS / Linux: `~/.ssh/config`.

What each line means:

| Line | Role |
|---|---|
| `Host aibeast` | The shortcut's name: `ssh aibeast` replaces `ssh -p PORT USER@ADDRESS` |
| `HostName`, `Port`, `User` | Address, SSH port and Linux account of the AI machine |
| `IdentityFile` | The **PC's** private key to use |
| `ServerAliveInterval 30`, `ServerAliveCountMax 3` | Detects a dead connection in ≈ 90 s instead of staying frozen |
| `GatewayPorts no` | The tunnels only listen on your PC (`127.0.0.1`): another machine on your network cannot use them |
| `ExitOnForwardFailure yes` | If a local port is already taken, the connection fails with a clear message instead of opening half the tunnels |
| `LocalForward 127.0.0.1:3000 127.0.0.1:3000` | Tunnel: port 3000 **of the PC** (on `127.0.0.1` only) leads to port 3000 **of the AI machine** |
| `LocalForward 127.0.0.1:13389 127.0.0.1:3389` | Remote desktop tunnel: port 13389 of the PC → 3389 of the AI machine (see §9) |

Test: `ssh aibeast` must open a terminal on the AI machine, without the account password.

## 6. Forbidding passwords (hardening) — only once the key works

**Before**: keep an SSH session open, and check `ssh aibeast` in a **second** window. Ideally, also install a key on a
**second device** (§7). Then, on the AI machine:

```bash
sudo tee /etc/ssh/sshd_config.d/10-durcissement.conf >/dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin no
# Your tunnels (LocalForward = ssh -L) stay allowed; reverse forwarding (ssh -R), VPN tunnels,
# the agent and X11 are not used here: forbidden. GatewayPorts no (default): nothing opens to the AI machine's network.
AllowTcpForwarding local
GatewayPorts no
PermitTunnel no
AllowAgentForwarding no
X11Forwarding no
EOF
sudo sshd -t && sudo systemctl reload ssh      # `sshd -t` checks the syntax before reloading
```

(*durcissement* = hardening; the file name is kept as on existing installations.)
Undo: `sudo rm /etc/ssh/sshd_config.d/10-durcissement.conf && sudo systemctl reload ssh`.

Lesson from the reference machine: passwords were forbidden **before** a key existed on the PC, and remote access was no
longer possible at all. Hence the order above.

## 7. A second key (fallback)

One key = one device. Do §4 from **a second device** (another PC, a phone with an SSH client): you will have two
independent paths. List of the keys allowed on the AI machine: `cat ~/.ssh/authorized_keys` (one line per key; the
comment at the end of the line tells the device). Remove a lost device: delete its line.

## 8. Tunnels to the interfaces

### Opening and closing

| System | Open | Close |
|---|---|---|
| Windows | double-click `windows\outils\Ouvrir-AiBeast.bat` (also opens the portal), or the console `windows\AiBeast.bat` | `windows\outils\Fermer-tunnels-AiBeast.bat` |
| All | `ssh -N aibeast` in a terminal (leave it open; `-N` = tunnels only, no terminal) | `Ctrl+C` in that terminal |

Then, in the PC's browser:

| Address on the PC | Service |
|---|---|
| http://127.0.0.1:3010 | **Portal** (entry point, links to everything else) |
| http://127.0.0.1:3011 | Button panel (`lab panel install`) |
| http://127.0.0.1:3000 | Open WebUI (chat) |
| http://127.0.0.1:5678 | n8n |
| http://127.0.0.1:6333/dashboard | Qdrant |
| http://127.0.0.1:8188 | ComfyUI (only in `lab mode images`) |
| http://127.0.0.1:3001 | Grafana |
| http://127.0.0.1:9090 | Prometheus |
| http://127.0.0.1:3002 | Langfuse (if installed) |
| http://127.0.0.1:2586 | ntfy (alerts) |
| http://127.0.0.1:9093 | Alertmanager |
| http://127.0.0.1:18789 | OpenClaw (if installed) |

### Common problems

| Message | Cause | Solution |
|---|---|---|
| `bind [127.0.0.1]:3000: Address already in use` then stop | A program on the PC already uses this port (or tunnels are already open) | Close the old tunnels; otherwise change the **first** number of the `LocalForward` line (e.g. `LocalForward 13000 127.0.0.1:3000`) and use that port in the browser |
| The page does not open, SSH works | The service is stopped on the AI machine | `lab status`, `lab start` (ComfyUI: `lab mode images`) |
| `Connection timed out` | Machine off, VPN down, wrong address | §11 |

## 9. The remote desktop (RDP)

### What it is for, what it costs

It shows the AI machine's graphical screen in a window on your PC. **It is not needed by the lab**: everything is driven
over SSH and the web interfaces. It is useful for a graphical application or a setting of the Ubuntu desktop.

Cost measured on the reference machine: during a remote desktop session, the card stays in state **P2** (≈ 123 W at
idle) instead of **P8** (≈ 17 to 43 W), i.e. **≈ 100 W more** ([remote-desktop-gpu.md](remote-desktop-gpu.md)).
Hence the rule: enable it on demand and close the session as soon as you are done.

### Which GNOME mode

Ubuntu offers two modes, in **Settings → System → Remote Desktop** (exact labels depend on the version):

| Mode | What it does | Service |
|---|---|---|
| **Remote Login** — **the one used here** | Opens the GNOME login screen: works even if nobody is logged in at the machine | **system** service `gnome-remote-desktop.service` (the one driven by `lab desktop`) |
| Desktop Sharing | Shares the session already open at the machine | **user** service; not handled by `lab desktop` |

### Setup (once, on the AI machine)

**With the graphical interface** (at the machine): Settings → System → Remote Desktop → **Remote Login** tab: enable,
then set the **RDP user name and password**. These credentials are specific to the remote desktop (not necessarily
those of your Linux account). Ubuntu creates the certificate itself.

**Or on the command line** (over SSH, without a screen) — procedure from Red Hat's GNOME documentation, not tested on
Ubuntu:

```bash
sudo -u gnome-remote-desktop mkdir -p ~gnome-remote-desktop/.local/share/gnome-remote-desktop
sudo -u gnome-remote-desktop winpr-makecert -silent -rdp -path ~gnome-remote-desktop/.local/share/gnome-remote-desktop tls
sudo grdctl --system rdp set-tls-key ~gnome-remote-desktop/.local/share/gnome-remote-desktop/tls.key
sudo grdctl --system rdp set-tls-cert ~gnome-remote-desktop/.local/share/gnome-remote-desktop/tls.crt
sudo grdctl --system rdp set-credentials        # asks for the RDP user name and password
sudo grdctl --system rdp enable
sudo systemctl enable --now gnome-remote-desktop.service
sudo grdctl --system status                     # check
```

**Do not open port 3389 in the firewall**: the remote desktop goes through the SSH tunnel (line
`LocalForward 127.0.0.1:13389 127.0.0.1:3389` of the configuration generated by `lab client`).

### Connecting from the PC

1. Open the tunnels (§8).
2. Start the RDP client to **`127.0.0.1:13389`** (the local port chosen by `LAB_RDP_LOCAL_PORT`):
   - Windows: "Remote Desktop Connection" (`mstsc`), computer `127.0.0.1:13389`;
   - macOS: Microsoft's **Windows App** (formerly "Microsoft Remote Desktop"), PC `127.0.0.1:13389`;
   - Linux: **Remmina**, RDP protocol, server `127.0.0.1:13389`.
3. Accept the certificate (it is self-signed; at the first connection only).
4. Enter the **RDP credentials** (setup above), then, on the GNOME login screen, your **Linux account**.

Why 13389 and not 3389? On Windows, the PC's port 3389 may be taken by its own remote desktop service; the tunnel would
then fail (`ExitOnForwardFailure`).

### Turning it on and off: `lab desktop`

```bash
lab desktop status          # active or not, started at boot or not, GPU state (P2/P8, watts)
lab desktop on              # starts the service
lab desktop off             # stops it: the card can go back down to P8
lab desktop off --boot      # stops it and prevents it from starting at boot
lab desktop on --boot       # starts it and re-enables it at boot
```

(`lab bureau` is the original name of the command and still works.)

**Only type `lab desktop off` from an SSH session**, never from the remote desktop itself: the session would be cut
under your fingers. The command reminds you and asks for confirmation if it does not detect an SSH session.
`lab doctor` reports the service as active (`!`), and the `GpuStuckInP2AtIdle` alert warns if the card stays in P2
without work.

## 10. Machine start-up: what comes back by itself?

The stack's containers have `restart: unless-stopped`: Docker restarts them **by itself** after a reboot, except those
stopped by hand (`docker stop`, `lab stop`).

| Project | Comes back by itself at boot? |
|---|---|
| `ai-stack` (Ollama, Open WebUI, n8n, Qdrant, SearXNG, Kokoro, Tika, Postgres) | Yes |
| `monitoring`, `portail`, `alerting` | Yes |
| `comfyui` | **No** (`restart: "no"`: it takes VRAM; `lab mode images` when needed) |
| `hermes` | **No** (started on demand) |
| `langfuse`, `openclaw` | Depending on their official compose (not verified) |

With a second disk (`8-stockage.sh docker`), Docker waits for the data disk to be mounted (`RequiresMountsFor=`): if
the disk is missing, Docker does not start, instead of starting again on an empty folder.

After a reboot: `lab doctor`.

## 11. Fallback if you are locked out

Symptom: `Permission denied (publickey)`, `Connection timed out` or no more answer.

1. The network: Windows `Test-NetConnection ADDRESS -Port 22`; macOS/Linux `nc -vz ADDRESS 22`.
   Failure = machine off, VPN down, wrong address or SSH stopped. Success = SSH answers, the problem is the key.
2. The key: `ssh -v aibeast` and look for "Offering public key"; no such line = no key found on this device (wrong
   `IdentityFile`?).
3. Try your **second device** (§7).
4. Last resort, at the machine (keyboard and screen):

```bash
sudo rm /etc/ssh/sshd_config.d/10-durcissement.conf     # restores password login
sudo systemctl reload ssh
```

Then redo §4 from your PC.

## 12. What is not verified

- `lab client`: the generated configuration was installed on the reference PC with `Installer-config-SSH.bat` and its
  tunnels are in use; it has not been tried on a second, new PC.
- The RDP tunnel (`127.0.0.1:13389`) and the command-line setup (`grdctl --system`) have not been tested; on the
  reference machine, the system service `gnome-remote-desktop` is active, but how it was enabled is not documented.
  Ubuntu menu labels quoted from memory: they may vary with the version.
- The ≈ 100 W cost comes from a single machine (RTX 3090, driver 595); the exact mechanism is not proven.
- RDP clients for macOS and Linux: quoted from common usage, not tested with this lab.
