# Installer le lab sur une nouvelle machine

Ce guide part d'une machine Linux neuve et va jusqu'à l'accès depuis ton ordinateur habituel. Compte 1 à 2 heures,
surtout pour les téléchargements (images Docker et modèles).

Vocabulaire utilisé partout :

- **la machine IA** : le PC Linux avec la carte graphique NVIDIA, où tourne tout le lab. Les scripts et la
  documentation l'appellent aussi **AiBeast** (nom de la machine d'origine du projet).
- **ton PC** (ou **le client**) : l'ordinateur depuis lequel tu travailles (Windows, macOS ou Linux). Il ne fait
  tourner aucun modèle : il se connecte à la machine IA par SSH.

## 1. Prérequis

### Matériel

| Élément | Minimum raisonnable | Machine de référence du projet |
|---|---|---|
| Carte graphique | NVIDIA avec 8 Go de VRAM ou plus | RTX 3090, 24 Go |
| Mémoire vive | 32 Go | 64 Go |
| Disque | 500 Go SSD (un seul disque suffit) | 480 Go système + 4 To données (`/data`) |
| Réseau | Ethernet conseillé | Ethernet, accès depuis l'extérieur par VPN |

Seules les cartes **NVIDIA** sont prises en charge par ces scripts (pilote propriétaire + NVIDIA Container Toolkit).

**Quelle taille de modèle pour ta carte ?** Ordre de grandeur, pour un modèle quantifié en 4 bits (format courant
dans Ollama) : environ 0,6 Go de VRAM par milliard de paramètres, plus 1 à 4 Go pour le contexte. À vérifier
ensuite avec `docker exec ollama ollama ps` : la colonne PROCESSOR doit afficher `100% GPU`.

| VRAM | Taille de modèle visée (4 bits) | Contexte de départ (`OLLAMA_CONTEXT_LENGTH`) |
|---|---|---|
| 8 Go | 7 à 8 milliards de paramètres | 8192 |
| 12 à 16 Go | 12 à 14 milliards | 16384 |
| 24 Go | 27 à 32 milliards | 32768 (65536 possible avec cache KV `q8_0`, mesuré sur la 3090) |

Ces chiffres sont indicatifs : seule la ligne 24 Go a été mesurée sur la machine de référence
(`docs/performance.md`). Les agents Hermes exigent 64 000 tokens de contexte, ce qui demande en pratique 24 Go.

### Logiciel

- **Ubuntu** (24.04 ou plus récent) ou Debian, ou un dérivé d'Ubuntu (Mint, Pop!_OS). La machine de référence est
  sous Ubuntu 26.04. Le script `1-prerequis.sh` installe Docker et le NVIDIA Container Toolkit depuis les dépôts
  officiels ; il ne gère pas Fedora, Arch, etc.
- **Le pilote NVIDIA déjà installé et actif** : `nvidia-smi` doit afficher ta carte. Sur Ubuntu :
  `sudo ubuntu-drivers install`, puis redémarrer.
- **Un compte utilisateur normal** avec le droit `sudo`. Ne lance jamais les scripts du lab avec `sudo` devant.
- **git** : `sudo apt install git`.

## 2. Récupérer le projet

Sur la machine IA :

```bash
mkdir -p ~/Documents && cd ~/Documents
git clone https://github.com/Mateo-lab/local-ai-lab.git ai-lab
cd ai-lab
```

(Ou l'adresse de ta copie du dépôt, si tu en as fait une.) Le dossier peut être ailleurs ; la documentation suppose
`~/Documents/ai-lab`.

## 3. Régler l'installation : `lab.conf`

```bash
cp lab.conf.example lab.conf
nano lab.conf
```

C'est **le seul fichier à adapter**. Il ne contient aucun secret et n'est jamais versionné. Chaque ligne est commentée
dans le fichier ; détail complet dans [configuration.md](configuration.md). Les réglages à regarder :

| Réglage | Quand le changer |
|---|---|
| `LAB_DATA_DIR` | Tu n'as **pas** de second disque monté sur `/data` : mets un dossier existant du disque système, par exemple `/srv/ai-lab` (créé avec `sudo mkdir -p /srv/ai-lab && sudo chown "$USER": /srv/ai-lab`) |
| `LAB_MODEL` | Pour fixer le modèle principal (sinon `lab` prend le plus gros modèle installé) |
| `LAB_HOST` | **Obligatoire pour l'accès à distance** : l'adresse par laquelle ton PC joindra la machine IA (voir étape 8) |
| `LAB_USER`, `LAB_SSH_PORT`, `LAB_SSH_KEY`, `LAB_RDP_LOCAL_PORT` | Seulement si tes valeurs diffèrent des défauts indiqués |

## 4. Installer Docker et le toolkit NVIDIA

```bash
./1-prerequis.sh
sudo reboot
```

Après le redémarrage : `docker run --rm --gpus all ubuntu nvidia-smi` doit afficher ta carte.

## 5. Créer les secrets et démarrer le cœur du lab

```bash
cd ~/Documents/ai-lab
./2-secrets.sh                  # crée les .env avec des mots de passe aléatoires (n'écrase jamais rien)
./3-demarrer.sh NOM_DU_MODELE   # démarre ai-stack et monitoring, et télécharge ce modèle
./lab install                   # crée la commande « lab » (lien dans ~/.local/bin)
lab start                       # démarre aussi le portail et les alertes
lab doctor                      # contrôle de santé complet
```

- `NOM_DU_MODELE` : un nom de la bibliothèque Ollama adapté à ta VRAM (tableau §1). Sans argument,
  `3-demarrer.sh` utilise `LAB_MODEL` de `lab.conf`, sinon ne télécharge rien.
- Ajuste ensuite le contexte dans `ai-stack/.env` (`OLLAMA_CONTEXT_LENGTH`, tableau §1), puis `lab start ai-stack`.
- `lab doctor` doit finir sans ✗. Un `!` est une remarque (par exemple « bureau à distance actif »).

## 6. Second disque (facultatif)

Si tu as un second disque **vide** pour les données :

```bash
./8-stockage.sh etat      # lister les disques : repère le bon nom (/dev/nvme1n1, /dev/sdb…)
./8-stockage.sh disque /dev/NOM_DU_DISQUE    # EFFACE ce disque, le formate et le monte sur LAB_DATA_DIR
./8-stockage.sh docker    # déplace les données de Docker sur ce disque
./3-demarrer.sh
```

`disque` **efface tout le disque indiqué** : vérifie trois fois le nom. Sans second disque, saute cette étape et
règle `LAB_DATA_DIR` (§3).

## 7. Modules facultatifs

À installer quand tu en as besoin, dans n'importe quel ordre :

| Module | Commande | Documentation |
|---|---|---|
| Génération d'images (ComfyUI) | `lab mode images` | [image-generation.md](image-generation.md) |
| Agent Hermes | `./5-hermes.sh NOM_DU_MODELE` | [agent-development.md](agent-development.md) |
| Suivi des agents (Langfuse) | `./6-langfuse.sh` | [agents-langfuse.md](agents-langfuse.md) |
| Banc d'essai | `./7-bench.sh check` | `bench/README.md` |
| Sauvegardes chiffrées | `lab backup init` puis `lab backup schedule` | [backups.md](backups.md) |
| Limite de puissance du GPU | `lab gpu-limit install 300` (valeur à adapter à ta carte) | [performance.md](performance.md) |
| Tri des mails Gmail (n8n) | voir la doc | [n8n-gmail.md](n8n-gmail.md) |
| OpenClaw | `./openclaw/install.sh` | `README.md` |

**Avant d'utiliser Hermes ou OpenClaw**, coupe-leur Internet : `lab isolation install` puis `lab isolation test`
([agent-isolation.md](agent-isolation.md)).

**Fais au moins les sauvegardes** : `lab backup init` affiche un mot de passe à garder **hors de la machine**
(gestionnaire de mots de passe).

## 8. Accès depuis ton PC

Tout est expliqué pas à pas dans [remote-access.md](remote-access.md). En résumé :

1. Sur la machine IA : `sudo apt install openssh-server`, puis renseigner `LAB_HOST` dans `lab.conf`.
2. Sur la machine IA : `lab client` génère la configuration SSH de ton PC et affiche la marche à suivre.
3. Sur ton PC : créer une clé SSH, la copier sur la machine IA, coller la configuration générée.
4. Sur ton PC : `ssh aibeast` doit répondre sans mot de passe ; `ssh -N aibeast` ouvre les tunnels, puis
   http://127.0.0.1:3010 affiche le portail.
5. Seulement ensuite : interdire la connexion SSH par mot de passe (durcissement).

Sous Windows, le dossier `windows/` du projet contient des raccourcis à double-cliquer (console à boutons, tunnels,
déploiement, copie des sauvegardes) : [windows-shortcuts.md](windows-shortcuts.md).

## 9. Vérifier l'exposition réseau

```bash
ss -tlnp | grep -vE '127\.0\.0\.1|\[::1\]|127\.0\.0\.53'
```

Ne doivent apparaître que **SSH (22)** et, s'il est activé, le **bureau à distance (3389)**. Toutes les interfaces
du lab écoutent sur `127.0.0.1` et ne sont joignables que par les tunnels SSH. Exception connue : OpenClaw publie
les ports 18789 et 3978 sur toutes les interfaces (compose officiel) : voir [openclaw.md](openclaw.md), section Sécurité.

## 10. Tenir à jour

| Je veux | Commande |
|---|---|
| Mettre à jour les images Docker (avec sauvegarde) | `lab update` (retour arrière : `lab rollback`) |
| Récupérer une nouvelle version du lab | `cd ~/Documents/ai-lab && git pull` puis `./2-secrets.sh` (complète les nouvelles variables) et `lab start` |
| Vérifier après un redémarrage | `lab doctor` |

ComfyUI est figé sur une version précise de son image : sa mise à jour se fait à la main
([image-generation.md](image-generation.md), « Installation durable »).

## Ce qui n'est pas vérifié

- Une installation complète sur une autre machine que la machine de référence (RTX 3090, Ubuntu 26.04) n'a jamais
  été faite : ce guide est écrit à partir des scripts et de l'installation d'origine.
- Le tableau des tailles de modèle par quantité de VRAM est indicatif, sauf la ligne 24 Go.
- `lab doctor` sur une machine à un seul disque (`LAB_DATA_DIR` sur le disque système) : la vérification a été adaptée,
  pas testée sur une vraie machine.
- `8-stockage.sh disque` n'a été utilisé que sur la machine de référence.
