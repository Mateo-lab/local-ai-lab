# local-ai-lab

Un labo d'IA **entièrement local** sur une seule machine Linux équipée d'une carte NVIDIA : chat (Open WebUI +
Ollama), automatisations (n8n), recherche web privée, voix, documents, génération d'images (ComfyUI), agents (Hermes,
OpenClaw) et leur suivi (Langfuse), supervision et alertes sur le téléphone, sauvegardes chiffrées, banc de mesure.
Le tout piloté par une seule commande, `lab`, et utilisable depuis un autre ordinateur par SSH, sans rien exposer sur
Internet.

- **Installer** : [docs/installation.md](docs/installation.md) (de la machine neuve à l'accès depuis ton PC).
- **Accès à distance** (SSH, tunnels, bureau à distance) : [docs/acces-distant.md](docs/acces-distant.md).
- **Régler ton installation** : un seul fichier, `lab.conf` ([docs/configuration.md](docs/configuration.md)).
- **Toute la documentation** : [docs/README.md](docs/README.md). Documentation en français.

Machine de référence (celle sur laquelle tout a été construit et mesuré) : RTX 3090 24 Go, 64 Go de RAM, Ubuntu 26.04,
appelée **AiBeast** dans les scripts. Les retours d'expérience et les mesures des docs viennent de cette machine.
Une installation sur un autre matériel n'a pas encore été faite : signale les problèmes rencontrés.

Licence : MIT (fichier `LICENSE`). Les logiciels lancés par le lab (Ollama, Open WebUI, n8n, ComfyUI, modèles…)
gardent chacun leur propre licence.

## Organisation

Plusieurs projets Docker séparés, chacun dans son dossier. Ils ne se parlent que par des réseaux
nommés, pour que chaque outil ne voie que ce dont il a besoin.

```
ai-lab/
├── ai-stack/    Ollama + Open WebUI + n8n (+ Postgres dédié) + Qdrant + SearXNG + Kokoro (voix) + Tika (documents)
├── monitoring/  Prometheus + Grafana + node-exporter + exporter GPU (+ règles d'alerte)
├── portail/     Page d'accueil unique (Homepage) : tous les services, voyants de santé, mesures de la machine
├── alerting/    Alertes : ntfy + Alertmanager + sondes (blackbox)
├── hermes/      Hermes Agent (agent à sous-agents)          — optionnel
├── openclaw/    OpenClaw (agent, installé à part)            — optionnel
├── comfyui/     ComfyUI (génération d'images)                — optionnel
├── langfuse/    Langfuse (suivi des appels des agents)       — optionnel
├── bench/       Banc d'essai (perf, cache KV, contexte, puissance GPU) — optionnel
├── windows/     Raccourcis Windows (console à boutons, tunnels, déploiement, copie des sauvegardes)
├── scripts/     Sauvegardes chiffrées, limite de puissance GPU, config SSH du client, accès des agents…
├── lab.conf.example   Réglages propres à TON installation (à copier en lab.conf)
├── docs/        Documentation détaillée (index : docs/README.md)
├── lab          LA commande de pilotage (lab doctor, lab start, lab update…)
└── 1-prerequis.sh … 8-stockage.sh    scripts guidés, à lancer dans l'ordre
```

```
 réseau          qui le partage
 ai-net          les services de ai-stack entre eux
 llm-net         Ollama + OpenClaw                (OpenClaw ne voit que Ollama)
 hermes-net      Ollama + Hermes                  (Hermes ne voit que Ollama)
 obs-net         Open WebUI + Hermes + Langfuse   (envoi des traces uniquement)
 mon-net         monitoring (isolé)
```

Tous les ports sont liés à `127.0.0.1` : rien n'est visible sur ton réseau local.

## Démarrage rapide

Prérequis : Ubuntu ou Debian, pilote NVIDIA actif (`nvidia-smi`), un compte avec `sudo`, git. Détail et choix du
modèle selon ta carte : [docs/installation.md](docs/installation.md).

Dans un terminal, avec ton utilisateur normal (**sans `sudo` devant les scripts** : ils demandent le mot de passe
eux-mêmes) :

```bash
git clone https://github.com/Mateo-lab/local-ai-lab.git ~/Documents/ai-lab && cd ~/Documents/ai-lab
cp lab.conf.example lab.conf && nano lab.conf   # disque de données, modèle, adresse pour l'accès distant
./1-prerequis.sh     # installe Docker + NVIDIA Container Toolkit, puis :  sudo reboot
./2-secrets.sh       # crée les fichiers .env avec des mots de passe aléatoires
./3-demarrer.sh NOM_DU_MODELE   # lance ai-stack et monitoring, télécharge le modèle
./lab install && lab start && lab doctor
lab client           # configuration SSH à coller sur ton PC (docs/acces-distant.md)
```

Ensuite, à ton rythme et dans l'ordre que tu veux (tous optionnels) :

```bash
./5-hermes.sh NOM_DU_MODELE   # agent Hermes (voir plus bas)
./6-langfuse.sh               # suivi des agents
./7-bench.sh check              # banc d'essai (optionnel, voir plus bas)
./8-stockage.sh etat            # 2e SSD : formatage et déplacement de Docker (optionnel)
./4-comfyui.sh                # images (à lancer seulement au besoin)
./openclaw/install.sh         # OpenClaw, en dernier
```

**Où sont les « secrets » / le `.env` ?** Les scripts les créent tout seuls, tu n'as rien à écrire :

- `ai-stack/.env` et `monitoring/.env`
- `langfuse/app/.env` (créé par `6-langfuse.sh`)

Ce sont des **fichiers cachés** (leur nom commence par un point) : `ls` ne les montre pas,
utilise `ls -a ai-stack`. Pour lire un fichier : `cat ai-stack/.env`.
Mot de passe Grafana : `grep GRAFANA_ADMIN_PASSWORD monitoring/.env`.

`./2-secrets.sh` peut être relancé à tout moment : il n'écrase aucune valeur, il complète seulement
les variables manquantes (utile après une mise à jour).

Si une étape échoue, copie-colle le message d'erreur complet.

## Où se trouve quoi

### Sur la machine IA (Linux)

| Chemin | Contenu | À savoir |
|---|---|---|
| `~/Documents/ai-lab/` | **Le projet** (ce dossier, dépôt git) : compose, scripts, `lab`, docs | C'est ici qu'on lance `./lab` |
| `…/ai-lab/lab.conf` | Réglages de **cette** installation | Jamais versionné ; modèle : `lab.conf.example` |
| `…/ai-lab/*/.env` | Secrets de chaque projet | Jamais écrasés par une mise à jour ; sauvegardés par `lab backup` |
| `…/ai-lab/.lab/` | Images mémorisées avant chaque `lab update` (pour `lab rollback`) | Créé au premier `lab update` |
| `…/ai-lab/bench/results/` | Résultats du banc d'essai (CSV, rapports HTML) | Sauvegardés |
| `/data/docker/` (`LAB_DATA_DIR`) | Racine de Docker : images, conteneurs et **volumes** (modèles Ollama, Open WebUI, n8n, Qdrant, bases) | SSD de 4 To. `lab doctor` vérifie que Docker y est |
| `/data/backups/restic/` | Dépôt des sauvegardes chiffrées | Même SSD que les données : voir `docs/sauvegardes.md` §3 |
| `~/.config/aibeast-backup/password` | Mot de passe du dépôt de sauvegardes | À copier ailleurs que sur la machine IA |
| `~/.local/bin/lab` | Lien vers `…/ai-lab/lab` | Créé par `./lab install` |
| `~/.ssh/authorized_keys` | Clés autorisées à se connecter en SSH | Une ligne par appareil |
| `/etc/ssh/sshd_config.d/` | Durcissement SSH (mot de passe interdit) | `docs/acces-distant.md` |
| `/etc/systemd/system/gpu-power-limit.service` | Limite de puissance GPU permanente | Créé par `lab gpu-limit install` |

Les données de chaque service sont dans des **volumes Docker** nommés (sous `/data/docker/volumes/`), pas dans le dossier du projet :
`ai-stack_ollama_data` (modèles), `ai-stack_open_webui_data`, `ai-stack_n8n_data`, `ai-stack_qdrant_data`,
`ai-stack_postgres_n8n_data`, `monitoring_prometheus_data`, `monitoring_grafana_data`. **Ne jamais utiliser `docker compose down -v`** :
il supprime ces volumes.

### Sur ton PC (client)

| Chemin (Windows ; macOS/Linux : `~/.ssh/…`) | Contenu |
|---|---|
| `%USERPROFILE%\.ssh\id_ed25519` | Ta clé **privée** SSH (ne jamais la copier ni l'envoyer) |
| `%USERPROFILE%\.ssh\id_ed25519.pub` | Ta clé publique (celle qui est dans `authorized_keys` de la machine IA) |
| `%USERPROFILE%\.ssh\config` | Raccourci `aibeast` et tunnels (bloc généré par `lab client`) |
| Un dossier de travail au choix | Le dossier `windows\` du projet, l'archive `ai-lab.tar.gz` à côté (si tu déploies depuis le PC), et `aibeast-backup\` (copie des sauvegardes) |

## Adresses (depuis la machine)

| Service | URL |
|---|---|
| **Portail (point d'entrée)** | http://127.0.0.1:3010 |
| Open WebUI | http://127.0.0.1:3000 |
| n8n | http://127.0.0.1:5678 |
| Qdrant | http://127.0.0.1:6333/dashboard |
| Ollama (API) | http://127.0.0.1:11434 |
| Grafana | http://127.0.0.1:3001 (utilisateur `admin`) |
| Prometheus | http://127.0.0.1:9090 |
| Langfuse | http://127.0.0.1:3002 |
| ComfyUI | http://127.0.0.1:8188 |
| OpenClaw | http://127.0.0.1:18789 |
| Alertes (ntfy) | http://127.0.0.1:2586/aibeast-alertes |
| Alertmanager | http://127.0.0.1:9093 |

Depuis un autre ordinateur : tunnel SSH, par exemple
`ssh -L 3000:127.0.0.1:3000 -L 5678:127.0.0.1:5678 UTILISATEUR@IP-DE-LA-MACHINE`.
Depuis Windows, tout est préparé dans `windows/` (un double-clic) : voir `docs/acces-distant.md`.

## Piloter avec `lab`

```bash
./lab install        # une fois : crée la commande `lab`
lab doctor           # santé complète (à lancer après chaque redémarrage)
lab start            # démarre tout dans l'ordre (ai-stack, monitoring, portail, alerting)
lab status | urls | logs SERVICE | models
lab update           # mise à jour avec sauvegarde, puis `lab rollback` si besoin
```
Référence complète : `docs/lab.md`. Toute la documentation : `docs/README.md`.

## Aide-mémoire des commandes

Sur la machine IA, dans un terminal. `lab` fonctionne de n'importe quel dossier après `./lab install`.

**Tous les jours**

| Je veux | Commande |
|---|---|
| Vérifier que tout va bien | `lab doctor` (après chaque redémarrage) |
| Voir l'état (conteneurs, GPU, disques) | `lab status` |
| Démarrer / arrêter tout | `lab start` / `lab stop` (ne supprime rien) |
| Démarrer / arrêter un seul projet | `lab start ai-stack` (ou `monitoring`, `portail`, `alerting`, `comfyui`, `langfuse`) / `lab stop comfyui` |
| Voir les adresses | `lab urls` |
| Voir les journaux d'un conteneur | `lab logs ollama` (Ctrl-C pour quitter) |
| Voir les modèles installés et chargés | `lab models` |

**Images (ComfyUI)**

| Je veux | Commande |
|---|---|
| **Lancer ComfyUI** (recommandé) | `lab mode images` : décharge les modèles Ollama de la VRAM, lance ComfyUI, attend qu'il réponde |
| Y accéder | `http://127.0.0.1:8188` sur AiBeast ; depuis Windows, double-clic sur `Ouvrir-AiBeast.bat` puis la même adresse |
| Arrêter ComfyUI et rendre la VRAM aux modèles | `lab mode normal` |
| Lancer ComfyUI sans décharger les modèles | `lab start comfyui` (le gros modèle chargé + SDXL ne tiennent pas ensemble en VRAM) |
| Arrêter ComfyUI seul | `lab stop comfyui` |
| Voir ce qu'il fait | `lab logs comfyui` (le tout premier démarrage peut durer ≈ 10 min) |

**Modes**

| Je veux | Commande |
|---|---|
| Voir le mode actuel, la VRAM libre | `lab mode status` |
| Libérer des ressources pour les agents | `lab mode agents` (arrête ComfyUI, Kokoro, Tika) |
| Revenir à la normale | `lab mode normal` |

**Maintenance**

| Je veux | Commande |
|---|---|
| Mettre à jour les images (avec sauvegarde) | `lab update` |
| Revenir aux images d'avant | `lab rollback` |
| Sauvegarder | `lab backup run` ; `lab backup list` ; `lab backup check` ; `lab backup restore ID DOSSIER` ; `lab backup init` / `lab backup schedule` (une fois) |
| Limite de puissance GPU | `lab gpu-limit status` ; `lab gpu-limit install 300` ; `lab gpu-limit remove` |
| Bureau à distance (≈ 100 W) | `lab bureau on` / `off` / `status` |
| Petit modèle pour les titres Open WebUI | `lab task-model NOM` (puis réglage dans l'interface, voir `docs/open-webui.md`) |

**Mesures** (arrêtent l'Ollama de production pendant le test ; à lancer dans `tmux`, elles demandent `sudo`)

| Je veux | Commande |
|---|---|
| Lister les expériences | `lab bench` |
| Lancer une expérience | `lab bench kv-decode --model qwen3.8:27b` (autres : `quick-smoke`, `power-sweep`, `power-confirm`, `context-scaling`, `ctx-window`, `kv-cache`, `kv-quality`, `prefix-cache`, `concurrency`) |
| Voir le plan sans rien lancer | ajouter `--dry-run` |
| Refaire un rapport | `lab bench report bench/results/<dossier>` |
| Comprendre les résultats | `docs/comprendre-les-mesures.md` |

**Installation initiale** (une seule fois, dans l'ordre ; sans `sudo` devant)

`./1-prerequis.sh` (puis `sudo reboot`) · `./2-secrets.sh` · `./3-demarrer.sh` · `./4-comfyui.sh` (ou `lab mode images`) ·
`./5-hermes.sh MODELE` · `./6-langfuse.sh` · `./7-bench.sh check` · `./8-stockage.sh etat` · `./openclaw/install.sh`

**Depuis le PC Windows** (dossier `windows\`, VPN connecté, clé SSH chargée). Le plus simple : double-clic sur `AiBeast.bat` (fenêtre avec des boutons). Les scripts individuels ci-dessous sont dans `windows\outils\`.

| Je veux | Fichier à double-cliquer |
|---|---|
| Ouvrir les tunnels vers les interfaces | `Ouvrir-AiBeast.bat` (fermer : `Fermer-tunnels-AiBeast.bat`) |
| Copier les sauvegardes chiffrées sur ce PC | `Sauvegarder-AiBeast-hors-machine.bat` |
| Envoyer une nouvelle version du lab sur AiBeast | `Deployer-sur-AiBeast.bat` |

## Mettre à jour le lab

```bash
cd ~/Documents/ai-lab
git status            # doit être propre (tes réglages sont dans lab.conf et les .env, ignorés par git)
git pull
./2-secrets.sh        # complète les variables ajoutées par la nouvelle version, sans rien écraser
lab start && lab doctor
```

Tu modifies le lab toi-même et tu le livres depuis un autre PC ? `scripts/release.sh` produit une archive des fichiers
commités, et `windows\outils\Deployer-sur-AiBeast.bat` l'envoie et l'extrait (refuse si le dépôt de la machine IA a
des modifications non commitées) : voir [docs/raccourcis-windows.md](docs/raccourcis-windows.md).

## ai-stack : Ollama, Open WebUI, n8n, Qdrant, SearXNG, Kokoro, Tika

Détail de ce que font les scripts 2 et 3 : `cd ai-stack`, `docker compose up -d`, `docker compose ps`.

**Sauvegarde `N8N_ENCRYPTION_KEY`** (dans `ai-stack/.env`) : sans elle, les identifiants stockés
dans n8n deviennent illisibles si tu recrées le volume.

**n8n tourne sur PostgreSQL** (service `postgres-n8n`, sans port publié), pas sur SQLite. Cette base
est séparée de celle de Langfuse, qui embarque la sienne.

### Modèle et contexte

```bash
docker exec ollama ollama list                       # modèles téléchargés
docker exec -it ollama ollama pull NOM_DU_MODELE
docker exec ollama ollama run NOM_DU_MODELE "Dis bonjour en une phrase"
docker exec ollama ollama ps      # PROCESSOR doit afficher 100% GPU ; CONTEXT = contexte servi
```

`ollama ps` n'affiche que les modèles **chargés** : une liste vide veut juste dire qu'aucun n'est en mémoire.
Si PROCESSOR montre un partage CPU/GPU, le modèle ou le contexte est trop grand pour 24 Go : baisse
`OLLAMA_CONTEXT_LENGTH` dans `ai-stack/.env` (puis `docker compose up -d`) ou prends un modèle plus petit.

**Contexte** : Hermes exige au moins 64 000 tokens et OpenClaw les recommande. Le défaut du projet est 32768 (prudent) :
mets `OLLAMA_CONTEXT_LENGTH=65536` dans `ai-stack/.env` pour les agents, avec le cache KV en `q8_0`
(déjà activé), et vérifie `ollama ps`.

Brancher les outils : n8n → Ollama `http://ollama:11434` ; n8n → Qdrant `http://qdrant:6333`.
Open WebUI est déjà configuré sur Ollama.

### Recherche web (SearXNG)

Méta-moteur privé, sans port publié : seul Open WebUI le joint. Format `json` activé (sans lui : erreur 403).

1. Open WebUI → Admin → Paramètres → Recherche web : activé, moteur `searxng`, URL `http://searxng:8080/search`.
2. Dans un chat : **+ Integrations → Web Search** (à refaire pour chaque chat).

Test : `docker exec open-webui curl -s "http://searxng:8080/search?q=test&format=json" | head -c 300`.
Les messages `ahmia` / `torch` (moteurs Tor) et `missing config file: limiter.toml` dans `docker logs searxng` sont sans gravité.

### Voix et documents (Kokoro, Tika)

- **Lecture à voix haute** : service `kokoro` (version CPU, aucune VRAM). Admin → Audio → Text-to-Speech :
  moteur OpenAI, URL `http://kokoro:8880/v1`, clé `not-needed` (n'importe quelle valeur), modèle `kokoro`, voix `af_bella`.
  Cette version de Kokoro n'a **que des voix anglaises** (`af_*`, `am_*`, `bf_*`, `bm_*`) : le français est lu avec un accent anglais.
- **Dictée** : bouton micro, Whisper local d'Open WebUI. Dans Admin → Audio → **Speech-to-Text**, le moteur doit rester
  celui par défaut (Whisper local) : Kokoro ne fait que la synthèse, et le mettre en STT donne une erreur 404.
- **Documents** : service `tika` (extraction PDF/Office pour le RAG). Admin → Paramètres → Documents : moteur Tika,
  URL `http://tika:9998`. Si l'extraction échoue, règle « Tika Server Version » (3.x ou 4.x) comme le serveur.
- Tests : `docker exec open-webui curl -s http://kokoro:8880/health` et `docker exec open-webui curl -s http://tika:9998/tika`.

## Monitoring (Prometheus + Grafana)

Projet indépendant. Démarré par `./3-demarrer.sh`.

Le tableau de bord « Labo IA » est chargé automatiquement : utilisation et température du GPU, VRAM sur 24 Go,
consommation, CPU, RAM, disque. Il n'utilise que les métriques GPU de l'exporter que j'ai pu confirmer
(utilisation, VRAM utilisée, puissance, température). Plus détaillé : Grafana → Dashboards → Import, ID `14574`.

Limites : `node-exporter` tourne en réseau bridge (les statistiques **réseau** affichées sont celles du conteneur) ;
Ollama n'expose pas de métriques Prometheus à ma connaissance ; le job OpenClaw est commenté dans
`monitoring/prometheus/prometheus.yml` (non testé) ; si `gpu-exporter` ne démarre pas : `docker logs gpu-exporter`.

### Limiter la puissance du GPU (recommandé)

Une 3090 tire jusqu'à 350 W. 300 W réduisent chaleur et bruit pour une perte de vitesse généralement faible
(à mesurer chez toi). Bornes acceptées : `nvidia-smi -q -d POWER`.

```bash
sudo nvidia-smi -pm 1 && sudo nvidia-smi -pl 300     # temporaire : perdu au redémarrage
```

**Permanent, en une commande : `lab gpu-limit install 300`** (voir `docs/performance.md` pour la mesure qui justifie 300 W).
Manuellement : un service systemd qui exécute `nvidia-smi -pm 1` puis `nvidia-smi -pl 300` au démarrage
(`/etc/systemd/system/gpu-power-limit.service`, type `oneshot`, `WantedBy=multi-user.target`),
puis `sudo systemctl enable --now gpu-power-limit.service`. Vérification : `nvidia-smi --query-gpu=power.limit --format=csv`.

## Hermes Agent (Nous Research) — optionnel

Projet `hermes/`, image officielle `nousresearch/hermes-agent`. Réseau `hermes-net` : Hermes ne voit **que Ollama**
(plus Langfuse via `obs-net` si tu l'installes). Pas de socket Docker, pas de port publié : il travaille dans son
conteneur, avec un seul dossier partagé, `hermes/data/`.

```bash
docker exec ollama ollama list        # nom exact du modèle
./5-hermes.sh NOM_DU_MODELE           # ouvre une discussion avec Hermes
```

- **Fichiers** : ce que tu déposes dans `hermes/data/workspace/` est vu par Hermes comme `/opt/data/workspace/`.
  Donne-lui toujours ce chemin-là (pas `hermes/...`, qui est le chemin sur ta machine). Ses PDF sont lus directement.
- **Contexte obligatoire** : 64 000 tokens minimum (voir « Modèle et contexte » plus haut).
- **Sous-agents** : Hermes sait en lancer. Avec `OLLAMA_NUM_PARALLEL=1` (défaut ici), leurs requêtes passent l'une
  après l'autre sur la 3090 : ça marche, mais sans gain de vitesse. Monter ce réglage multiplie la mémoire de contexte
  et peut faire déborder la VRAM.
- Le conteneur est jetable (`--rm`) : seul ce qui est dans `hermes/data/` est conservé.
- **Fermer le terminal arrête la session** (conteneur `hermes-session-…` supprimé), même si la connexion SSH tombe.
  Pour qu'une session survive à une coupure, lance-la dans `tmux`. `lab doctor` signale une session en marche depuis
  plus de 12 h.

## Langfuse (suivi des agents) — optionnel

Langfuse enregistre chaque appel au modèle : prompts, réponses, durée, tokens, outils utilisés par l'agent.
Il utilise le `docker-compose.yml` **officiel** (cloné dans `langfuse/app`) avec une surcharge qui le lie à
`127.0.0.1:3002` (3000 = Open WebUI, 9090 = Prometheus) et le met sur `obs-net`. Besoin recommandé par Langfuse :
4 cœurs, 16 Go de RAM, ~100 Go de disque. Cette installation Compose n'a ni haute disponibilité ni sauvegarde.

```bash
cd ai-stack && docker compose up -d && cd ..   # crée le réseau obs-net
./6-langfuse.sh                                # clone, génère les secrets, démarre, affiche compte et clés
```

Compte, mot de passe et clés d'API sont créés d'avance et écrits dans `langfuse/app/.env` (caché).

- **Open WebUI** : Admin → Fonctions → nouvelle fonction (filtre Langfuse, code sur
  https://docs.openwebui.com/tutorials/integrations/monitoring/langfuse), puis dans ses Valves : clé publique,
  clé secrète, hôte `http://langfuse-web:3000`. Activer en « Global ». Garder le SDK Langfuse en v3.
- **Hermes** : `./5-hermes.sh MODELE plugins install langfuse`, puis dans `hermes/data/.env` :
  `HERMES_LANGFUSE_PUBLIC_KEY`, `HERMES_LANGFUSE_SECRET_KEY`, `HERMES_LANGFUSE_BASE_URL=http://langfuse-web:3000`
  (et `HERMES_LANGFUSE_CAPTURE=metadata` pour n'envoyer ni prompts ni réponses). Non vérifié : le plugin doit
  survivre à la fermeture du conteneur ; contrôle avec `plugins list` au lancement suivant.

## Images (ComfyUI) — optionnel

Projet séparé `comfyui/`, **à lancer seulement quand tu en as besoin** (il prend beaucoup de VRAM). Image
**communautaire** (`ghcr.io/clsferguson/comfyui-docker`, MIT), figée par son empreinte dans
`comfyui/docker-compose.yml` ; mise à jour et réglages durables : [docs/generation-images.md](docs/generation-images.md).

```bash
./4-comfyui.sh          # décharge les modèles Ollama puis démarre ComfyUI
./4-comfyui.sh stop     # arrête et libère la VRAM
```

1. Dépose un modèle d'image (`.safetensors`) dans `comfyui/data/models/checkpoints/`, relance `./4-comfyui.sh`.
2. Dans ComfyUI : Settings → « Dev Mode », charge un workflow qui marche, File → **Export (API)** (fichier JSON).
3. Open WebUI → Admin → Paramètres → **Images** : moteur **ComfyUI**, URL `http://comfyui:8188`, importe le JSON,
   vérifie la correspondance des champs (prompt, modèle, taille, étapes, seed).
4. Dans un chat : **+ Integrations → Image**.

## Banc d'essai (benchmark) — optionnel

Projet `bench/` : mesures chiffrées avec intervalles de confiance (vitesse, cache KV, contexte, parallélisme,
**perte de performance selon la limite de puissance du GPU**). Il démarre son propre Ollama de test et arrête
temporairement celui de production.

```bash
./7-bench.sh check
./7-bench.sh run quick-smoke --model qwen3.8:27b     # ~5 min
./7-bench.sh run power-sweep --model qwen3.8:27b     # courbe puissance → tok/s, J/token, °C
```

Rapport HTML dans `bench/results/…/report.html`. Méthode et limites : `bench/README.md`.
Non vérifié sur ton matériel : le banc n'a été testé qu'avec un faux GPU et un faux Ollama.

## OpenClaw — optionnel

Prérequis : `ai-stack` tourne (il crée le réseau `llm-net`) et un modèle est téléchargé.

```bash
./openclaw/install.sh
```

Le script clone le dépôt officiel, ajoute un override (la gateway rejoint `llm-net`), puis lance l'installateur officiel.
Réponses à donner : provider **Ollama**, mode **Local only**, URL `http://ollama:11434` (pas `host.docker.internal`),
modèle téléchargé. Interface : http://127.0.0.1:18789/ avec le jeton `OPENCLAW_GATEWAY_TOKEN` de `~/openclaw/.env`.

Commandes utiles (depuis `~/openclaw`) :

```bash
docker compose run --rm openclaw-cli dashboard --no-open     # réafficher l'URL
docker compose run --rm openclaw-cli models list --provider ollama
docker compose logs -f openclaw-gateway
```

Mise à jour : `cd ~/openclaw && git pull && docker compose pull && docker compose up -d`.
**Important :** le script officiel appelle `docker compose -f docker-compose.yml`, qui ignore l'override réseau. Après toute recréation de la passerelle (mise à jour, `up -d`), rattache-la à Ollama : `docker network connect llm-net $(docker compose -f docker-compose.yml ps -q openclaw-gateway)` (sans effet si elle y est déjà ; `./openclaw/install.sh` le fait aussi).
Installation réelle, pièges et sécurité (ports 18789 et 3978 publiés sur toutes les interfaces) : [docs/openclaw.md](docs/openclaw.md).

## Stockage (second SSD sur /data) — optionnel

Système sur un disque, données lourdes (images Docker, volumes dont les modèles Ollama) sur un second disque monté sur
`LAB_DATA_DIR` (`/data` par défaut). Machine de référence : NVMe 480 Go + SSD 4 To. Sans second disque, saute cette
section et règle `LAB_DATA_DIR` dans `lab.conf`.

```bash
./8-stockage.sh etat      # disques, /data, racine Docker
./8-stockage.sh disque /dev/NOM   # EFFACE ce disque (nom obligatoire, voir « etat »), ext4, monté via fstab
./8-stockage.sh docker    # arrête les conteneurs, copie Docker vers /data/docker, data-root + garde-fou systemd
./3-demarrer.sh           # puis relancer les services
```

L'ancien dossier reste dans `/var/lib/docker.old` jusqu'à ce que tu le supprimes. Non testé sur du vrai matériel.
Sauvegardes : le SSD seul n'est pas une sauvegarde (copie chiffrée vers un autre support à prévoir).

## Arrêter ou éteindre la machine

Tu peux simplement éteindre : Docker arrête proprement ses conteneurs, les données restent dans les volumes, et
les services reviennent seuls au démarrage (sauf ComfyUI, et Hermes qui n'est lancé qu'à la demande).
Pour tout arrêter proprement avant :

```bash
for d in ai-stack monitoring comfyui langfuse/app; do (cd $d 2>/dev/null && docker compose stop); done
(cd ~/openclaw 2>/dev/null && docker compose stop)
```

Relancer : `./3-demarrer.sh`, puis `docker compose up -d` dans `langfuse/app` et `~/openclaw` si installés.
**N'utilise jamais `docker compose down -v`** : l'option `-v` supprime les volumes (conversations, workflows, modèles).

## Sécurité (à lire avant de donner des outils à un agent)

Vue d'ensemble avec diagrammes (réseaux, ports, accès, agents, risques restants) :
[docs/architecture-securite.md](docs/architecture-securite.md).

- **Agents sans Internet** : Hermes et OpenClaw ne joignent qu'Ollama (et Langfuse) ; Internet, le réseau local et la
  machine elle-même leur sont fermés, sauf SSH vers les machines de test que tu autorises : `lab isolation install`,
  [docs/isolation-agents.md](docs/isolation-agents.md).

- **Vérifie l'exposition** : `ss -tlnp | grep -E '18789|3000|3001|3002|5678|6333|8188|9090|11434'`. Aucun ne doit écouter sur
  `0.0.0.0`. Le port 18789 d'OpenClaw est publié par son compose officiel : sinon, restreins-le par pare-feu
  (Docker contourne UFW ; voir la chaîne `DOCKER-USER`).
- **Accès à distance** : tunnels SSH par le réseau local ou un VPN (Tailscale, WireGuard…), jamais de port ouvert sur
  Internet : [docs/acces-distant.md](docs/acces-distant.md).
- **Données** : ne monte pas tes dossiers personnels dans un conteneur d'agent. Ne copie que ce dont il a besoin.
- **Comptes** : au début, pas de mails ni de comptes réels connectés. Un agent qui lit du contenu externe
  (web, mails, messages) peut être manipulé par ce contenu (injection de prompt).
- **Secrets** : traite `ai-stack/.env`, `langfuse/app/.env` et `~/openclaw/.env` comme des identifiants.
- **Plugins et fonctions** (Open WebUI, Hermes) : ils exécutent du code sur ta machine ; lis-les avant de les installer.
- **Sauvegardes** : volumes `ollama_data`, `n8n_data`, `postgres_n8n_data`, `qdrant_data`, `open_webui_data`,
  `grafana_data`, les volumes de Langfuse, et les dossiers `hermes/data`, `comfyui/data`, `~/.openclaw`. Sans oublier
  les fichiers `.env`.

## Dépannage rapide

| Symptôme | Piste |
|---|---|
| `docker: command not found` | `./1-prerequis.sh` n'est pas allé au bout ; relance-le et lis la fin du message |
| `apt` : « Release … n'est pas encore valable » | L'horloge de la machine est fausse : `sudo timedatectl set-ntp true` |
| `apt` : verrou `dpkg` occupé (`unattended-upgr`) | Mise à jour automatique en cours ; attends : `pgrep -a unattended-upgr` |
| `could not select device driver "nvidia"` | NVIDIA Container Toolkit non configuré : `./1-prerequis.sh` |
| `network llm-net / hermes-net / obs-net not found` | Lance d'abord `ai-stack` (`docker compose up -d`) |
| SearXNG en boucle : `settings.yml is a directory` | Docker a créé un faux dossier : `docker compose stop searxng`, `sudo rm -r ai-stack/searxng/settings.yml`, `sudo chown "$USER": ai-stack/searxng`, recopie le vrai fichier, puis `docker compose rm -sf searxng && docker compose up -d searxng` |
| Dictée : 404 sur `/audio/transcriptions` | Le moteur STT pointe vers Kokoro : remets Whisper local (Admin → Audio → STT) |
| Voix introuvable (`Voice "…" not found`) | Choisis une voix de la liste (`af_bella`…) dans Admin → Audio |
| Hermes ne trouve pas un fichier | Utilise le chemin vu par Hermes : `/opt/data/workspace/…` |
| Hermes refuse de démarrer | Contexte < 64000 : `OLLAMA_CONTEXT_LENGTH=65536`, puis `docker compose up -d` |
| OpenClaw n'atteint pas Ollama | `docker compose run --rm openclaw-cli doctor --json` ; URL `http://ollama:11434` |
| Réponses très lentes | `docker exec ollama ollama ps` : le modèle déborde sur le CPU |
| n8n : cookie/connexion refusée en http | `N8N_SECURE_COOKIE=false` dans `ai-stack/.env` |
