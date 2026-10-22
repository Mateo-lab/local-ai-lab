# La commande `lab`

Une seule commande pour tout piloter. Fichier : `lab` (à la racine du projet).

## Installation
```bash
cd ~/ai-lab && ./lab install     # crée le lien ~/.local/bin/lab
lab doctor
```
Si `~/.local/bin` n'est pas dans ton PATH, la commande l'indique (ligne à ajouter à `~/.bashrc`).

## Référence

| Commande | Effet |
|---|---|
| `lab status` | Tous les conteneurs, GPU (état, watts, °C, VRAM), disques `/` et `/data` |
| `lab doctor` | Contrôle de santé (voir ci-dessous). Code de sortie ≠ 0 s'il y a un problème |
| `lab start [projet]` | Démarre tout dans l'ordre `ai-stack → monitoring → portail → alerting`, ou un seul projet (aussi `comfyui`, `langfuse`) |
| `lab stop [projet]` | Arrête (`docker compose stop`) : **ne supprime ni conteneurs ni volumes** |
| `lab logs SERVICE [n]` | Journaux en direct d'un conteneur (Ctrl-C pour quitter) |
| `lab urls` | Adresses de toutes les interfaces |
| `lab models` | Modèles installés et modèles chargés en VRAM |
| `lab task-model NOM` | Voir `open-webui.md` §1 |
| `lab bench [nom] [...]` | Banc d'essai. Sans nom : liste. Le modèle est celui qui est chargé (sinon le premier installé) ; force-le avec `--model NOM` ou `LAB_MODEL=NOM` |
| `lab gpu-limit status\|install [W]\|remove` | Voir `performance.md` §1 |
| `lab bureau on\|off\|status [--boot]` | Bureau à distance à la demande : voir `acces-distant.md` §9 |
| `lab client [--print]` | Génère la configuration SSH du PC (raccourci `aibeast`, tunnels, bureau à distance) depuis `lab.conf` : `acces-distant.md` §5 |
| `lab backup init\|run\|list\|check\|restore\|schedule` | Voir `sauvegardes.md` |
| `lab config [list\|set MODEL NOM]` / `lab main-model` | Modèle principal mémorisé (voir `docs/raccourcis-windows.md`) |
| `lab.conf` (facultatif, à la racine du projet) | Réglages propres à la machine : `LAB_DATA_DIR`, `LAB_MODEL`, accès distant `LAB_HOST`… (voir `docs/configuration.md`) |
| `lab backup repo` | Affiche l'emplacement du dépôt de sauvegarde (utilisé par la copie hors machine depuis Windows) |
| `lab tmux update\|backup\|doctor` | Action longue dans une session tmux (survit à une coupure SSH) |
| `lab dev new\|list\|start\|review\|check\|merge\|setup\|ctx64` | Développement avec Hermes : `docs/developpement-agents.md` |
| `lab panel install\|token\|status\|logs\|uninstall` | Panneau web à boutons : `docs/panneau-web.md` |
| `lab remote add\|show\|link\|list\|test\|remove` | Accès SSH de Hermes à une machine de test : `docs/hermes-ssh.md` |
| `lab mode agents\|images\|normal\|status` | Voir « Mode agents » et « Mode images » ci-dessous |
| `lab update [--no-backup]` / `lab rollback` | Voir ci-dessous |

`ComfyUI`, `Hermes`, `Langfuse` et `OpenClaw` gardent leurs scripts (`4-comfyui.sh`, `5-hermes.sh`, `6-langfuse.sh`,
`openclaw/install.sh`) pour l'installation. `lab start comfyui|langfuse` ne fait que `docker compose up -d`
dans leur dossier, une fois installés.

## Mode agents : libérer des ressources sans perdre l'observation

```bash
lab mode status     # mode actuel, VRAM libre, modèles chargés, 8 conteneurs les plus gourmands en RAM
lab mode agents     # arrête ComfyUI, Kokoro et Tika ; affiche la VRAM avant/après
lab mode images     # décharge les modèles Ollama de la VRAM et lance ComfyUI (voir « Mode images »)
lab mode normal     # relance Kokoro et Tika ; depuis le mode images, arrête aussi ComfyUI
```
**Ce que fait et ne fait pas ce mode.** Il arrête les services dont les agents n'ont pas besoin. Il ne touche ni à Ollama,
ni à Open WebUI, n8n, Qdrant, SearXNG, ni à la supervision, ni à **Langfuse** : Langfuse sert à observer les agents, l'arrêter
pendant qu'ils travaillent supprimerait la trace de ce qu'ils font.

**Ce qu'il faut en attendre.** La contrainte réelle d'un agent local est la **VRAM** (24 Go, dont ≈ 17 Go pour le modèle de
27 milliards de paramètres et son cache de contexte). Seul ComfyUI y pèse. Kokoro et Tika tournent sur le processeur : les
arrêter économise de la RAM et un peu de CPU, **pas de VRAM**. Avec 64 Go de RAM, le gain est modeste ; le mode sert surtout à
garantir que ComfyUI est éteint et à voir l'état des ressources d'un coup d'œil. Pour savoir si d'autres services valent la peine
d'être arrêtés, regarde `lab mode status` pendant une session d'agent plutôt que de supposer.

**Persistance.** Le mode est mémorisé dans `.lab/mode`. Tant qu'il est « agents », `lab start`, `lab update` et `lab rollback`
remettent ces trois services à l'arrêt, et `lab doctor` ne les compte pas comme manquants. Après un redémarrage de la machine,
Docker ne relance pas un conteneur arrêté à la main (`unless-stopped`) : le mode reste donc cohérent.

Pour changer la liste des services arrêtés : variable `AGENT_PAUSE` en tête du script `lab`.

## Mode images : faire de la place à ComfyUI

```bash
lab mode images     # décharge les modèles Ollama, lance ComfyUI, attend que l'interface réponde (http://127.0.0.1:8188)
lab mode normal     # arrête ComfyUI (libère la VRAM pour les modèles Ollama), relance Kokoro et Tika
```
**Pourquoi.** Mesuré le 2026-10-18 : `qwen3.8:27b` chargé occupe ≈ 20 Go de VRAM sur 24 ; il ne reste pas assez de place pour
SDXL (≈ 7 Go) qui bascule alors sur la RAM, plus lent. Les deux ne tiennent pas ensemble : il faut alterner.

**Ce que fait le mode.** (1) `ollama stop` sur chaque modèle chargé ; (2) `docker compose up -d` de ComfyUI ; (3) attente de la réponse
de l'interface, jusqu'à 3 min (le tout premier démarrage peut durer ≈ 10 min : message d'attente, pas une erreur) ;
(4) affiche la VRAM avant/après. Kokoro et Tika restent actifs (ils n'utilisent pas la VRAM).

**Limite à connaître.** Le mode ne *verrouille* pas Ollama : si Open WebUI, n8n ou un agent envoie une requête à un modèle,
celui-ci se recharge dans la VRAM (≈ 20 Go) et reprend la place de ComfyUI. En mode images, évite de discuter avec un modèle.
`lab doctor` ne signale plus un GPU en P2 sans modèle chargé quand ComfyUI tourne (c'était une fausse alerte pendant une génération).

## Langfuse

Installé séparément (`./6-langfuse.sh`, clone du dépôt officiel dans `langfuse/app`). Une fois installé, `lab start`, `lab update` et
`lab doctor` le prennent en compte automatiquement (détection de `langfuse/app/docker-compose.yml`). Il lance une
dizaine de conteneurs (web, worker, ClickHouse, Redis, MinIO, PostgreSQL) : mesure sa consommation avec `lab mode status`.
Branchement de Hermes, pièges et API de lecture : `docs/agents-langfuse.md`.

## `lab doctor`

Contrôle : Docker actif ; racine Docker sur `/data` ; `/data` monté ; les 17 conteneurs attendus en marche ; aucun
conteneur `unhealthy` ; GPU (limite, état, watts, température) ; bureau à distance ; occupation des disques (> 85 % =
remarque) ; modèle entièrement sur GPU ; âge de la dernière sauvegarde.
`✗` = problème (code de sortie 1) ; `!` = remarque (à connaître, pas bloquant).

## Mises à jour contrôlées

### Principe
Les images utilisent des étiquettes mobiles (`:latest`, `:main`). Une mise à jour peut donc casser quelque chose sans
prévenir. `lab update` rend l'opération **réversible** et **vérifiée** :

1. sauvegarde chiffrée (si configurée ; sinon avertissement. `--no-backup` pour passer) ;
2. mémorise, pour chaque conteneur en marche, `référence de l'image → identifiant exact` dans `.lab/images-DATE.tsv` ;
3. `docker compose pull` puis `up -d` pour chaque projet ;
4. attend 30 s, liste les images qui ont changé, lance `lab doctor`.

Si `doctor` signale un problème : `lab rollback`.

### Retour arrière
`lab rollback` re-étiquette les anciennes images (`docker tag`) sous leur nom d'origine puis relance les projets.

> **Limite connue (corrigée le 2026-10-19, non testée sur AiBeast) :** lors de la première mise à jour réelle, les conteneurs Langfuse
> (projet Docker nommé `app`, pas `langfuse`) n'étaient pas mémorisés : MinIO a été mis à jour sans pouvoir être restauré par `lab rollback`.
> Le script cherche maintenant le projet par le nom du dossier. Les mises à jour déjà faites ne sont pas concernées.
- Fonctionne **tant que les anciennes images existent encore** sur le disque. Ne lance pas `docker image prune` ni
  `docker system prune -a` avant d'être sûr de la mise à jour. Les anciennes images restent après un `pull` (sans
  étiquette) ; elles occupent de la place sur `/data`.
- Il ne touche **pas aux données** (volumes). Si la nouvelle version a migré une base vers un format plus récent,
  l'ancienne image peut refuser de la lire : il faut alors restaurer la sauvegarde (`sauvegardes.md` §4). C'est la
  raison de la sauvegarde automatique à l'étape 1.

### Rythme conseillé
Pas de mise à jour automatique. Une fois par mois, ou quand une fonction t'intéresse : `lab update`, puis un test
d'usage (une conversation Open WebUI, un workflow n8n) avant de supprimer les anciennes images
(`docker image prune`, jamais `-a`).

## Ce qui n'est pas vérifié

- **`lab` n'a jamais tourné sur ta machine** : syntaxe contrôlée (`bash -n`), `help`, `urls`, `install` (dans un
  dossier personnel factice) et l'écriture de `.env` (`task-model`) testés ici. Tout ce qui parle à Docker, au GPU ou
  à systemd (`status`, `doctor`, `start`, `update`, `rollback`, `bureau`…) est **non testé** : Docker n'existe pas dans
  l'environnement où j'ai écrit le script.
- `lab update` couvre `ai-stack`, `monitoring`, `portail`, `alerting` et Langfuse (s'il est installé). ComfyUI, Hermes et OpenClaw se
  mettent à jour avec leurs propres scripts/dossiers.
- `lab mode agents` et `lab mode images` sont vérifiés sur ta machine (2026-10-18) : déchargement d'Ollama, démarrage de ComfyUI, VRAM 0,4 Go puis 7,0 Go avec SDXL, génération ≈ 15 s. Retour `lab mode normal` depuis le mode images vérifié aussi : ComfyUI arrêté, VRAM à 0,1 Go, `lab doctor` sans remarque.
- Le retour arrière suppose des images locales intactes ; il ne gère pas les images référencées par empreinte (`@sha256`).
- `lab doctor` suppose les noms de conteneurs de la liste `EXPECTED` en tête du script `lab`; adapte-la si tu en ajoutes ou retires.
