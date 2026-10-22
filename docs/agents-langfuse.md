# Agents et Langfuse

Langfuse enregistre ce que font les agents : chaque tour de conversation, chaque appel au modèle (durée, tokens),
chaque outil utilisé. Tout reste sur AiBeast (`http://127.0.0.1:3002`).

Résultat vérifié le 2026-10-18 : **Hermes → Langfuse fonctionne** (2 traces, 4 observations après une conversation).
OpenClaw n'est pas branché (voir §6).

## 1. Installer Langfuse

```bash
cd ~/Documents/ai-lab
./6-langfuse.sh
```
Le script clone le dépôt officiel dans `langfuse/app`, génère les secrets (`langfuse/app/.env`), lance ~6 services
(web, worker, ClickHouse, Redis, MinIO, PostgreSQL) et attend que Langfuse réponde.
La surcharge `langfuse/docker-compose.override.yml` (copiée dans `langfuse/app/`) :
- lie l'interface à `127.0.0.1:3002` et MinIO à `127.0.0.1:9092/9091` (le compose officiel publie sur toutes les interfaces) ;
- joint Langfuse au réseau `obs-net` (partagé avec Open WebUI et Hermes) ;
- fixe `HOSTNAME=0.0.0.0` pour `langfuse-web` : sans cela, Next.js n'écoute que sur la première adresse du conteneur
  et le portail (sonde de santé) et les agents, qui passent par `obs-net`, reçoivent « Connection refused ».

Santé : `docker exec homepage wget -qO- http://langfuse-web:3000/api/public/health` → `{"status":"OK",...}`.

## 2. Brancher Hermes

1. Langfuse : créer une organisation et un projet `hermes`, puis Settings → API Keys → Create (clé publique `pk-lf-…`, clé secrète `sk-lf-…`, affichée une seule fois).
2. Écrire les variables dans `hermes/data/.env` (fichier lu par Hermes, inclus dans la sauvegarde chiffrée) :
   ```
   HERMES_LANGFUSE_PUBLIC_KEY=pk-lf-…
   HERMES_LANGFUSE_SECRET_KEY=sk-lf-…
   HERMES_LANGFUSE_BASE_URL=http://langfuse-web:3000
   HERMES_LANGFUSE_ENV=local
   ```
   Une seule fois chacune : l'installateur du plugin écrit déjà ces lignes ; ne les ajoute pas une seconde fois.
3. Installer le plugin : `cd hermes && docker compose run --rm hermes plugins install langfuse`
   (dans la version testée, `plugins enable observability/langfuse` répond « Langfuse moved out of core » : c'est un plugin du catalogue officiel, version 2.0.0).
4. Vérifier : `docker compose run --rm hermes plugins list --plain --no-bundled | grep -i langfuse` → `enabled`.
5. Tester : `./5-hermes.sh MODELE chat`, écrire un message, attendre la réponse, `/exit`, attendre ~10 s.
   Dans Langfuse (projet `hermes`) : une trace « Hermes turn » avec l'appel au modèle.

Confidentialité : par défaut le plugin envoie le contenu des échanges en masquant les secrets (`sanitized`).
`HERMES_LANGFUSE_CAPTURE=metadata` n'envoie que durées, tokens et noms d'outils.
`HERMES_LANGFUSE_DEBUG=true` n'est utile que pour diagnostiquer : retire-le ensuite.

## 3. Ce qui a coûté du temps (à éviter)

| Symptôme | Cause | Remède |
|---|---|---|
| Aucune trace, aucune erreur visible | Le plugin échoue en silence (clés ou adresse fausses) | Journaux : `hermes/data/logs/errors.log` (**horodatés en UTC**, 2 h de moins que l'heure de Bruxelles en heure d'été) |
| `Failed to resolve 'langfuse-web'` | `hermes/docker-compose.yml` sans `obs-net` (copie antérieure à l'ajout) | Ajouter `- obs-net` aux réseaux du service **et** déclarer `obs-net: {external: true, name: obs-net}` en bas. Ne pas écraser le fichier si tu as ajouté d'autres volumes (ex. `./workspace:/workspace`) |
| `Input is not a terminal`, saisie mélangée | `./5-hermes.sh … chat \| tee fichier` : Hermes a besoin d'un vrai terminal | Ne jamais rediriger ni passer par `tee` ; lire les journaux dans `hermes/data/logs/` |
| `HTTP 404 … Langfuse v4 events_only mode` sur `/api/public/traces` | Langfuse v4 a retiré cet ancien point d'accès | Utiliser `GET /api/public/v2/observations?fromStartTime=…&limit=10` (basic auth clé publique:clé secrète). Avec certains clients, délai possible de 15 min |
| `docker compose run` bloqué sur `Creating` après Ctrl+C / Ctrl+Z | Conteneurs `hermes-hermes-run-*` orphelins | `docker ps -aq --filter name=hermes-hermes-run \| xargs -r docker rm -f` |

Vérifier sans l'interface (les clés ne sont jamais affichées) :
```bash
cd ~/Documents/ai-lab/hermes
set -a; . ./data/.env; set +a
curl -s -G -u "$HERMES_LANGFUSE_PUBLIC_KEY:$HERMES_LANGFUSE_SECRET_KEY" \
  "http://127.0.0.1:3002/api/public/v2/observations" \
  --data-urlencode "fromStartTime=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)" --data-urlencode "limit=10"
unset HERMES_LANGFUSE_PUBLIC_KEY HERMES_LANGFUSE_SECRET_KEY HERMES_LANGFUSE_BASE_URL HERMES_LANGFUSE_ENV
```

## 4. Mode agents (`lab mode agents`)

Libère de la VRAM et de la RAM pour les agents : arrête ComfyUI, Kokoro et Tika. Ollama, Open WebUI, n8n, Qdrant,
SearXNG, la supervision et **Langfuse** restent actifs. Retour : `lab mode normal` (ne relance pas ComfyUI :
`lab start comfyui`). Détail : `docs/lab.md`.

## 5. ComfyUI : premier démarrage

- L'image fait ~8 Go. Si la session SSH peut couper pendant le téléchargement, lancer en arrière-plan :
  `nohup ./lab start comfyui > ~/comfyui-start.log 2>&1 &`.
- Premier démarrage : le conteneur exécute `chown -R` sur toute la bibliothèque Python. Charge disque forte, CPU à 0 %,
  **plusieurs minutes sans message** (observé : ~6 min). L'interface (`http://127.0.0.1:8188`) répond ensuite ; ne
  relance pas le conteneur pendant cette étape. Elle se refait si le conteneur est recréé (`lab update`).
- Modèles : `comfyui/data/models/checkpoints/`. Exemple vérifié : SDXL base 1.0 (6,9 Go) téléchargé avec
  `nohup wget -c -O sd_xl_base_1.0.safetensors https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors`.
  Non sauvegardés (se retéléchargent).

## 5 bis. Partage de la VRAM : Ollama contre ComfyUI (mesuré le 2026-10-18)

| Situation | VRAM utilisée |
|---|---|
| `qwen3.8:27b` chargé (17 Go de modèle, contexte 65 536) + ComfyUI allumé | 20,8 Go / 24 Go |
| Après `lab mode agents` (ComfyUI, Kokoro, Tika arrêtés) | 20,2 Go |
| Après `lab mode images` (modèle Ollama déchargé, ComfyUI démarré, SDXL pas encore chargé) | 0,4 Go |
| SDXL base 1.0 chargé dans ComfyUI après une génération (mode images) | 7,0 Go |

Le modèle de langage seul occupe ~20 Go : SDXL (~7 Go) ne tient pas à côté et ComfyUI bascule sur un fonctionnement avec
déchargement en RAM (plus lent ; sa mémoire vive montait à 5,3 Go). Les deux usages demandent donc d'alterner :
le modèle Ollama se décharge seul après son délai d'inactivité (colonne `UNTIL` de `ollama ps`), ou à la main avec
`docker exec ollama ollama stop NOM_DU_MODELE`. `lab mode images` automatise cette bascule (voir `docs/lab.md`).
Mesuré avec `lab mode images` : démarrage de ComfyUI en quelques secondes (interface prête après ~25 s), VRAM à 0,4 Go avant la première génération,
**génération SDXL en ≈ 15 s**, 7,0 Go de VRAM une fois le modèle chargé. SDXL (7 Go) + `qwen3.8:27b` (~20 Go) = ~27 Go > 24 Go : l'alternance est nécessaire.
La durée de génération *avant* le mode images (modèle Ollama chargé, ComfyUI en repli RAM) n'a pas été chronométrée : pas de comparaison chiffrée.

## 6. OpenClaw

Non branché. OpenClaw est volontairement isolé sur `llm-net`, hors de `obs-net`. Il possède un plugin de traces
(`diagnostics-otel`, protocole OpenTelemetry) qui pourrait viser Langfuse (`/api/public/otel`), mais cela imposerait de
le joindre à `obs-net` et donc de relâcher son isolement. Décision à prendre explicitement ; rien n'a été fait.

## 7. Sauvegarde de Langfuse

`lab backup run` sauvegarde la base PostgreSQL de Langfuse (comptes, projets, clés API, prompts) et son `.env`.
Le conteneur est retrouvé par le dossier de son compose (`langfuse/app`), pas par le nom de projet (Docker le nomme `app`).
**Non sauvegardés** : ClickHouse (les traces elles-mêmes) et MinIO.

## Ce qui n'est pas vérifié

- `lab mode agents` : testé avec ComfyUI allumé et `qwen3.8:27b` chargé dans Ollama (2026-10-18). ComfyUI, Kokoro et Tika s'arrêtent
  et reviennent ; la VRAM passe de 20,8 à 20,2 Go (seulement 0,6 Go libérés). La libération d'un modèle d'image **entièrement chargé** n'est pas mesurée.
- Le contenu exact d'une trace (niveau de détail du mode `sanitized`) n'a pas été relu dans l'interface.
- Branchement d'OpenClaw, et de n8n ou Open WebUI comme sources de traces : non fait.
- Une mise à jour de l'image Hermes (`:stable`) peut changer le plugin ; le retester après `lab update`.
- Restauration de la base Langfuse : testée le 2026-10-18 (snapshot restauré dans `~/restore-test`, `langfuse.sql` chargé dans un PostgreSQL jetable de même image : code de sortie 0, 1 utilisateur, 2 projets, 2 clés API). Non testé : la remise en service réelle (réinjecter la base dans Langfuse) ni la restauration de ClickHouse (non sauvegardé).
