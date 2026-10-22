# Accès à distance : SSH, tunnels et bureau à distance

Objectif : utiliser toutes les interfaces du lab depuis ton PC, chez toi comme à l'extérieur, **sans rien exposer sur
Internet**, sans jamais te retrouver bloqué dehors, et sans payer ≈ 100 W de plus en continu pour un bureau à distance.

## 1. Le principe

```
 TON PC                                   RÉSEAU                         MACHINE IA (AiBeast)
 navigateur → 127.0.0.1:3010 ─┐
 navigateur → 127.0.0.1:3000 ─┤
 client RDP → 127.0.0.1:13389 ┤   un seul canal chiffré :     ┌→ 127.0.0.1:3010  portail
 terminal   → ssh aibeast   ──┴── SSH (port 22) ─────────────→ sshd ─┼→ 127.0.0.1:3000  Open WebUI
                                  réseau local, VPN ou Tailscale     ├→ …                (toutes les interfaces)
                                                                     └→ 127.0.0.1:3389  bureau à distance (RDP)
```

- Sur la machine IA, **toutes les interfaces écoutent seulement sur `127.0.0.1`** : personne sur le réseau ne peut
  les joindre directement, même pas toi.
- **SSH est la seule porte d'entrée.** Une fois connecté, SSH transporte des « tunnels » : ton PC écoute sur ses propres
  ports (`127.0.0.1:3000` sur le PC) et fait suivre chaque connexion vers le même port de la machine IA. Dans ton
  navigateur, tu tapes donc `http://127.0.0.1:3000` comme si tu étais assis devant la machine IA.
- Le **bureau à distance** (voir l'écran graphique de la machine IA) passe par le même canal : il n'est jamais ouvert
  directement sur le réseau.

| Chemin | À quoi il sert | Coût | Dépend de |
|---|---|---|---|
| **SSH par clé** | Administration (terminal, `lab`), et transport de tout le reste | nul | réseau + clé |
| **Tunnels SSH** | Ouvrir les interfaces web dans le navigateur du PC | nul | SSH |
| **Bureau à distance** (GNOME Remote Desktop, RDP) | Voir et utiliser l'écran de la machine IA | **≈ 100 W** pendant une session (GPU maintenu en P2, mesuré) | SSH + service activé |

SSH est aussi le chemin de **secours** : si tout le reste est cassé, SSH permet de réparer. Il ne faut jamais le
rendre inutilisable (voir §6 avant de durcir).

## 2. Comment ton PC joint la machine IA (`LAB_HOST`)

Choisis **une** façon, puis note l'adresse correspondante dans `lab.conf` (`LAB_HOST=…`) :

| Situation | Adresse à mettre dans `LAB_HOST` | Remarques |
|---|---|---|
| Même réseau local (maison) | IP locale de la machine IA : `hostname -I` sur la machine IA | Réserve cette IP dans ta box (bail DHCP fixe), sinon elle peut changer |
| VPN existant (box, routeur, entreprise) | IP de la machine IA vue à travers le VPN | C'est le cas de la machine de référence |
| Tailscale (VPN maillé, gratuit pour un usage personnel) | Nom ou IP Tailscale de la machine IA (`tailscale ip -4`) | À installer sur la machine IA **et** sur le PC ; aucun port à ouvrir sur la box |
| WireGuard que tu gères | IP de la machine IA dans le tunnel WireGuard | Demande d'ouvrir un port UDP sur la box pour WireGuard, pas pour SSH |

**N'ouvre jamais le port 22 (SSH) ni 3389 (bureau à distance) de ta box vers Internet.** Passe par le réseau local
ou par un VPN.

## 3. Installer le serveur SSH sur la machine IA

```bash
sudo apt install openssh-server
systemctl status ssh          # doit afficher « active (running) »
```

À ce stade, la connexion par **mot de passe** est encore permise : elle sert une seule fois, pour copier ta clé.

## 4. La clé SSH de ton PC

Une clé SSH est une paire de fichiers créée **sur ton PC** :
- la clé **privée** (`id_ed25519`) reste sur le PC, ne se copie jamais, ne s'envoie jamais ;
- la clé **publique** (`id_ed25519.pub`) se copie sur la machine IA, dans `~/.ssh/authorized_keys`.

### Windows (PowerShell)

Le client SSH est inclus dans Windows 10 et 11. `ssh-copy-id` n'existe pas sous Windows ; la 2ᵉ commande fait la même
chose. Remplace `UTILISATEUR` et `ADRESSE` (ou copie la commande toute prête affichée par `lab client`).

```powershell
# 1. Créer la clé (Entrée pour l'emplacement par défaut ; une phrase secrète est recommandée)
ssh-keygen -t ed25519

# 2. Copier la clé PUBLIQUE sur la machine IA (le mot de passe du compte Linux est demandé cette fois)
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh UTILISATEUR@ADRESSE "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# 3. Tester : doit se connecter SANS demander le mot de passe du compte
ssh UTILISATEUR@ADRESSE
```

### macOS / Linux (Terminal)

```bash
ssh-keygen -t ed25519
ssh-copy-id UTILISATEUR@ADRESSE
ssh UTILISATEUR@ADRESSE        # doit se connecter sans mot de passe du compte
```

Si tu as mis une phrase secrète, elle est demandée à chaque connexion. Pour ne la taper qu'une fois par session :
agent SSH (Windows : service « OpenSSH Authentication Agent » puis `ssh-add` ; macOS : `ssh-add --apple-use-keychain`).

## 5. La configuration SSH du PC (`lab client`)

Pour ne pas retaper l'adresse et la liste des tunnels, ton PC garde un **raccourci** nommé `aibeast` dans son fichier
de configuration SSH. Tous les scripts de `windows/` utilisent ce nom.

Sur la machine IA :

```bash
lab client
```

La commande lit `lab.conf` (`LAB_HOST`, `LAB_USER`, `LAB_SSH_PORT`, `LAB_SSH_KEY`, `LAB_RDP_LOCAL_PORT`), affiche le bloc
de configuration, l'écrit aussi dans `windows/ssh_config_aibeast.txt` (fichier propre à ta machine, ignoré par git),
et rappelle la marche à suivre. Exemple de bloc : `windows/ssh_config_aibeast.example`.

**Sous Windows, le plus simple** : copie `windows/ssh_config_aibeast.txt` dans le dossier `windows\` du PC (par exemple
`scp aibeast:Documents/ai-lab/windows/ssh_config_aibeast.txt windows\` si l'ancien raccourci marche encore), puis
double-clic sur `windows\outils\Installer-config-SSH.bat` : il sauvegarde ta configuration, remplace l'ancien bloc
`aibeast` (ou l'ajoute) sans toucher aux autres. Sinon, à la main :

Sur ton PC, **ajoute ce bloc à la fin** du fichier de configuration SSH (le créer s'il n'existe pas, sans extension) :
- Windows : `C:\Users\TON_NOM\.ssh\config` (dans PowerShell : `notepad $env:USERPROFILE\.ssh\config`) ;
- macOS / Linux : `~/.ssh/config`.

Ce que signifie chaque ligne :

| Ligne | Rôle |
|---|---|
| `Host aibeast` | Le nom du raccourci : `ssh aibeast` remplace `ssh -p PORT UTILISATEUR@ADRESSE` |
| `HostName`, `Port`, `User` | Adresse, port SSH et compte Linux de la machine IA |
| `IdentityFile` | La clé privée **du PC** à utiliser |
| `ServerAliveInterval 30`, `ServerAliveCountMax 3` | Détecte une connexion morte en ≈ 90 s au lieu de rester figé |
| `ExitOnForwardFailure yes` | Si un port local est déjà pris, la connexion échoue avec un message clair au lieu d'ouvrir des tunnels à moitié |
| `LocalForward 3000 127.0.0.1:3000` | Tunnel : le port 3000 **du PC** mène au port 3000 **de la machine IA** |
| `LocalForward 13389 127.0.0.1:3389` | Tunnel du bureau à distance : port 13389 du PC → 3389 de la machine IA (voir §8) |

Test : `ssh aibeast` doit ouvrir un terminal sur la machine IA, sans mot de passe du compte.

## 6. Interdire le mot de passe (durcissement) — seulement quand la clé marche

**Avant** : garde une session SSH ouverte, et vérifie `ssh aibeast` dans une **seconde** fenêtre. Idéalement, installe
aussi une clé sur un **second appareil** (§7). Puis, sur la machine IA :

```bash
sudo tee /etc/ssh/sshd_config.d/10-durcissement.conf >/dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF
sudo sshd -t && sudo systemctl reload ssh      # `sshd -t` vérifie la syntaxe avant de recharger
```

Annuler : `sudo rm /etc/ssh/sshd_config.d/10-durcissement.conf && sudo systemctl reload ssh`.

Leçon de la machine de référence : le mot de passe a été interdit **avant** qu'une clé existe sur le PC, et plus aucun
accès à distance n'était possible. D'où l'ordre ci-dessus.

## 7. Une deuxième clé (secours)

Une clé = un appareil. Fais §4 depuis **un second appareil** (autre PC, téléphone avec un client SSH) : tu auras deux
chemins indépendants. Liste des clés autorisées sur la machine IA : `cat ~/.ssh/authorized_keys` (une ligne par clé ;
le commentaire en fin de ligne indique l'appareil). Retirer un appareil perdu : supprimer sa ligne.

## 8. Les tunnels vers les interfaces

### Ouvrir et fermer

| Système | Ouvrir | Fermer |
|---|---|---|
| Windows | double-clic sur `windows\outils\Ouvrir-AiBeast.bat` (ouvre aussi le portail), ou la console `windows\AiBeast.bat` | `windows\outils\Fermer-tunnels-AiBeast.bat` |
| Tous | `ssh -N aibeast` dans un terminal (le laisser ouvert ; `-N` = tunnels seulement, pas de terminal) | `Ctrl+C` dans ce terminal |

Puis, dans le navigateur du PC :

| Adresse sur le PC | Service |
|---|---|
| http://127.0.0.1:3010 | **Portail** (point d'entrée, liens vers tout le reste) |
| http://127.0.0.1:3011 | Panneau de boutons (`lab panel install`) |
| http://127.0.0.1:3000 | Open WebUI (chat) |
| http://127.0.0.1:5678 | n8n |
| http://127.0.0.1:6333/dashboard | Qdrant |
| http://127.0.0.1:8188 | ComfyUI (seulement en `lab mode images`) |
| http://127.0.0.1:3001 | Grafana |
| http://127.0.0.1:9090 | Prometheus |
| http://127.0.0.1:3002 | Langfuse (si installé) |
| http://127.0.0.1:2586 | ntfy (alertes) |
| http://127.0.0.1:9093 | Alertmanager |
| http://127.0.0.1:18789 | OpenClaw (si installé) |

### Problèmes fréquents

| Message | Cause | Solution |
|---|---|---|
| `bind [127.0.0.1]:3000: Address already in use` puis arrêt | Un programme du PC utilise déjà ce port (ou des tunnels sont déjà ouverts) | Fermer les anciens tunnels ; sinon changer le **premier** nombre de la ligne `LocalForward` (ex. `LocalForward 13000 127.0.0.1:3000`) et utiliser ce port dans le navigateur |
| La page ne s'ouvre pas, SSH marche | Le service est arrêté sur la machine IA | `lab status`, `lab start` (ComfyUI : `lab mode images`) |
| `Connection timed out` | Machine éteinte, VPN coupé, mauvaise adresse | §11 |

## 9. Le bureau à distance (RDP)

### À quoi il sert, ce qu'il coûte

Il affiche l'écran graphique de la machine IA dans une fenêtre de ton PC. **Il n'est pas nécessaire au lab** : tout se
pilote par SSH et par les interfaces web. Il est utile pour une application graphique ou un réglage du bureau Ubuntu.

Coût mesuré sur la machine de référence : pendant une session de bureau à distance, la carte reste en état **P2**
(≈ 123 W au repos) au lieu de **P8** (≈ 17 à 43 W), soit **≈ 100 W de plus** ([remote-desktop-gpu.md](remote-desktop-gpu.md)).
D'où la règle : on l'active à la demande et on ferme la session dès qu'on a fini.

### Quel mode GNOME

Ubuntu propose deux modes, dans **Paramètres → Système → Bureau à distance** (intitulés exacts selon la version) :

| Mode | Ce qu'il fait | Service |
|---|---|---|
| **Connexion à distance** (*Remote Login*) — **celui utilisé ici** | Ouvre l'écran de connexion GNOME : marche même si personne n'est connecté devant la machine | service **système** `gnome-remote-desktop.service` (celui que pilote `lab bureau`) |
| Partage du bureau (*Desktop Sharing*) | Partage la session déjà ouverte devant la machine | service **utilisateur** ; pas géré par `lab bureau` |

### Mise en place (une fois, sur la machine IA)

**Avec l'interface graphique** (devant la machine) : Paramètres → Système → Bureau à distance → onglet
**Connexion à distance** : activer, puis définir le **nom d'utilisateur et le mot de passe RDP**. Ces identifiants sont
propres au bureau à distance (ce ne sont pas forcément ceux de ton compte Linux). Ubuntu crée lui-même le certificat.

**Ou en ligne de commande** (par SSH, sans écran) — procédure de la documentation Red Hat pour GNOME, non testée sur
Ubuntu :

```bash
sudo -u gnome-remote-desktop mkdir -p ~gnome-remote-desktop/.local/share/gnome-remote-desktop
sudo -u gnome-remote-desktop winpr-makecert -silent -rdp -path ~gnome-remote-desktop/.local/share/gnome-remote-desktop tls
sudo grdctl --system rdp set-tls-key ~gnome-remote-desktop/.local/share/gnome-remote-desktop/tls.key
sudo grdctl --system rdp set-tls-cert ~gnome-remote-desktop/.local/share/gnome-remote-desktop/tls.crt
sudo grdctl --system rdp set-credentials        # demande le nom d'utilisateur et le mot de passe RDP
sudo grdctl --system rdp enable
sudo systemctl enable --now gnome-remote-desktop.service
sudo grdctl --system status                     # vérifier
```

**N'ouvre pas le port 3389 dans le pare-feu** : le bureau à distance passe par le tunnel SSH (ligne
`LocalForward 13389 127.0.0.1:3389` de la configuration générée par `lab client`).

### Se connecter depuis le PC

1. Ouvrir les tunnels (§8).
2. Lancer le client RDP vers **`127.0.0.1:13389`** (le port local choisi par `LAB_RDP_LOCAL_PORT`) :
   - Windows : « Connexion Bureau à distance » (`mstsc`), ordinateur `127.0.0.1:13389` ;
   - macOS : application **Windows App** de Microsoft (ex-« Microsoft Remote Desktop »), PC `127.0.0.1:13389` ;
   - Linux : **Remmina**, protocole RDP, serveur `127.0.0.1:13389`.
3. Accepter le certificat (il est auto-signé ; à la première connexion seulement).
4. Saisir les **identifiants RDP** (mise en place ci-dessus), puis, sur l'écran de connexion GNOME, ton **compte Linux**.

Pourquoi 13389 et pas 3389 ? Sous Windows, le port 3389 du PC peut être occupé par son propre service de bureau à
distance ; le tunnel échouerait alors (`ExitOnForwardFailure`).

### L'allumer et l'éteindre : `lab bureau`

```bash
lab bureau status          # actif ou non, démarrage automatique ou non, état du GPU (P2/P8, watts)
lab bureau on              # démarre le service
lab bureau off             # l'arrête : la carte peut redescendre en P8
lab bureau off --boot      # l'arrête et l'empêche de démarrer au boot
lab bureau on --boot       # le démarre et le réactive au boot
```

**Ne tape `lab bureau off` que depuis une session SSH**, jamais depuis le bureau à distance lui-même : la session se
couperait sous tes doigts. La commande le rappelle et demande confirmation si elle ne détecte pas de session SSH.
`lab doctor` signale le service actif (`!`), et l'alerte `GpuBloqueEnP2AuRepos` prévient si la carte reste en P2 sans
travail.

## 10. Démarrage de la machine : qui revient tout seul ?

Les conteneurs de la stack ont `restart: unless-stopped` : Docker les relance **seul** après un redémarrage, sauf ceux
arrêtés à la main (`docker stop`, `lab stop`).

| Projet | Revient seul au boot ? |
|---|---|
| `ai-stack` (Ollama, Open WebUI, n8n, Qdrant, SearXNG, Kokoro, Tika, Postgres) | Oui |
| `monitoring`, `portail`, `alerting` | Oui |
| `comfyui` | **Non** (`restart: "no"` : il prend la VRAM ; `lab mode images` au besoin) |
| `hermes` | **Non** (lancé à la demande) |
| `langfuse`, `openclaw` | Selon leur compose officiel (non vérifié) |

Avec un second disque (`8-stockage.sh docker`), Docker attend le montage du disque de données
(`RequiresMountsFor=`) : si le disque manque, Docker ne démarre pas, au lieu de repartir sur un dossier vide.

Après un redémarrage : `lab doctor`.

## 11. Secours si tu es bloqué dehors

Symptôme : `Permission denied (publickey)`, `Connection timed out` ou plus de réponse.

1. Le réseau : Windows `Test-NetConnection ADRESSE -Port 22` ; macOS/Linux `nc -vz ADRESSE 22`.
   Échec = machine éteinte, VPN coupé, mauvaise adresse ou SSH arrêté. Réussite = SSH répond, le problème est la clé.
2. La clé : `ssh -v aibeast` et cherche « Offering public key » ; aucune ligne = pas de clé trouvée sur cet appareil
   (`IdentityFile` faux ?).
3. Essaie ton **second appareil** (§7).
4. Dernier recours, devant la machine (clavier et écran) :

```bash
sudo rm /etc/ssh/sshd_config.d/10-durcissement.conf     # rétablit la connexion par mot de passe
sudo systemctl reload ssh
```

Puis refais §4 depuis ton PC.

## 12. Ce qui n'est pas vérifié

- `lab client` : testé seulement en générant le fichier ; la configuration produite n'a pas encore été collée sur un
  nouveau PC. Elle reprend les mêmes tunnels que la configuration de la machine de référence, plus la ligne RDP.
- Le tunnel RDP (`127.0.0.1:13389`) et la mise en place en ligne de commande (`grdctl --system`) n'ont pas été testés ;
  sur la machine de référence, le service système `gnome-remote-desktop` est actif, mais la façon dont il a été activé
  n'est pas documentée. Intitulés des menus Ubuntu repris de mémoire : ils peuvent varier selon la version.
- Le coût de ≈ 100 W vient d'une seule machine (RTX 3090, pilote 595) ; le mécanisme exact n'est pas prouvé.
- `Ouvrir-AiBeast.ps1` et la console Windows n'ont jamais été exécutés par l'assistant qui les a écrits.
- Clients RDP macOS et Linux : cités d'après leur usage courant, non testés avec ce lab.
