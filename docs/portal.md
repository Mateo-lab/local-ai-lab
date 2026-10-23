# Portail (page d'accueil)

Une page unique avec un bouton par service, un **voyant de santé** (vert = répond, rouge = ne répond pas) et des
**mesures de la machine** (GPU, mémoire, disques). Dossier : `portail/`. Outil : [Homepage](https://gethomepage.dev).

## Démarrer

```bash
lab start portail          # ou : cd portail && docker compose up -d
```
Adresse : **http://127.0.0.1:3010**

Prérequis : `ai-stack` **et** `monitoring` démarrés (ils créent les réseaux `ai-stack_ai-net`, `obs-net`, `mon-net`
que le portail rejoint). Sinon Docker répond « network … declared as external, but could not be found » :
lance d'abord `lab start` (qui respecte l'ordre).

## Ce que montre la page

| Groupe | Contenu |
|---|---|
| Interfaces | Open WebUI, n8n, ComfyUI, Qdrant |
| Moteur et outils | Ollama, SearXNG, Kokoro, Tika (voyants uniquement) |
| Observabilité | Grafana, Prometheus, Langfuse |
| Agents (à la demande) | OpenClaw (lien, sans voyant), Hermes (carte d'information) |
| Machine | GPU (puissance, température, charge, état P-state, VRAM), RAM, disque système, disque `/data` |

Le **voyant** est une requête HTTP faite depuis le conteneur du portail vers chaque service (option `siteMonitor`).
Un service non démarré (ComfyUI, Langfuse) apparaît rouge : c'est normal. **Langfuse n'est pas lancé par `lab start`** et
n'est pas installé tant que `./6-langfuse.sh` n'a pas tourné : sa carte restera rouge jusque-là.

### OpenClaw et Hermes : pourquoi pas de voyant
- **Hermes** n'a aucune interface web (agent en ligne de commande, conteneur lancé à la demande par `./5-hermes.sh`,
  `restart: "no"`) : il n'y a rien à sonder, la carte est informative.
- **OpenClaw** écoute sur `127.0.0.1:18789` **de la machine**, dans son propre projet Docker. Pour le sonder, le portail devrait
  rejoindre `llm-net` (réseau partagé avec Ollama et OpenClaw), ce qui romprait leur isolation (« OpenClaw ne voit que
  Ollama »). Choix fait : un lien sans voyant. Le port est dans les tunnels générés par `lab client`
  (ligne `LocalForward 18789`) : présent dans la configuration SSH de ton PC si tu l'as collée en entier.
- Pour un voyant sans toucher aux réseaux, la solution propre serait un sonde dans `blackbox` ou une règle d'alerte
  dédiée : non faite, parce qu'OpenClaw n'est pas démarré en permanence.

L'état **P-state** du GPU est utile : `P8` = repos (≈ 20 W), `P2` = un programme garde le GPU en mode calcul (≈ 120 W).
Voir `docs/remote-desktop-gpu.md`.

## Fichiers

| Fichier | Rôle |
|---|---|
| `portail/docker-compose.yml` | Conteneur Homepage, port `127.0.0.1:3010`, 3 réseaux externes |
| `portail/config/services.yaml` | Liste des services, voyants, cartes de mesures |
| `portail/config/settings.yaml` | Titre, thème, langue, disposition des groupes |
| `portail/config/widgets.yaml` | Date/heure et ressources du conteneur portail |
| `portail/config/bookmarks.yaml` | Liens de référence externes |

Après une modification d'un fichier de `config/`, Homepage la recharge seul (sinon `docker compose restart homepage`).

### Ajouter un service
Dans `services.yaml`, sous un groupe : un nom, `href` (adresse à ouvrir), `description`, `icon`, et `siteMonitor`
(adresse interne `http://nom-du-conteneur:port`). Le conteneur doit être sur un réseau que le portail rejoint
(`ai-net`, `mon-net` ou `obs-net`) ; sinon ajoute ce réseau dans `portail/docker-compose.yml`.

### Ajouter une mesure
Une carte = une requête Prometheus. Modèle : `url: http://prometheus:9090/api/v1/query?query=REQUETE` (REQUETE encodée
pour une URL : `*` → `%2A`, `{` → `%7B`, `"` → `%22`, `/` → `%2F`), `field: data.result.0.value.1`.

## Accès depuis ton PC Windows

Un seul double-clic : voir [`remote-access.md`](remote-access.md) (fichiers du dossier `windows/`).
Les tunnels transportent les mêmes numéros de ports, donc les liens du portail fonctionnent à l'identique sur Windows.

## Sécurité

- Le portail est lié à `127.0.0.1` (rien n'est exposé sur le réseau).
- **Aucun accès au socket Docker** : si le portail était compromis, il ne donnerait pas les droits root sur la machine.
  C'est pour cela que les voyants passent par HTTP et non par l'intégration Docker de Homepage.
- `HOMEPAGE_ALLOWED_HOSTS` n'autorise que `127.0.0.1:3010` et `localhost:3010`. Si tu changes le port du tunnel côté
  Windows, ajoute le nouveau nom dans cette variable.

## Ce qui n'est pas fait, et pourquoi

- **Adresses lisibles (`webui.aibeast`)** avec un reverse proxy : non fait. Chaque service mémorise sa propre adresse
  (Langfuse : `NEXTAUTH_URL`, n8n : `WEBHOOK_URL`, Grafana : `root_url`, cookies d'Open WebUI). Les placer derrière un
  nom différent demande de les reconfigurer un par un, avec un risque de connexion cassée. Le gain (ne plus retenir
  des ports) est déjà couvert par le portail.

## Non vérifié (écrit sans pouvoir lancer Docker)

- Le nom des icônes (`open-webui.png`, `comfyui.png`…) : s'il manque, la carte s'affiche sans icône.
- Les chemins de santé : `n8n /healthz`, `qdrant /healthz`, `grafana /api/health`, `prometheus /-/healthy`,
  `langfuse /api/public/health` sont les chemins usuels. `kokoro /docs` et `tika /tika` sont des pages qui répondent
  par défaut, à confirmer.
- Les cartes de mesures : les noms de métriques (`nvidia_smi_*`, `node_*`) viennent de la documentation du
  `nvidia_gpu_exporter`. Si une carte affiche « Erreur », ouvre Prometheus (`:9090`) et tape le nom de la métrique pour
  voir si elle existe sous ce nom exact.
- `format: bytes` pour la VRAM : la valeur arrive de Prometheus sous forme de texte ; si l'affichage est faux, passe à
  `format: float` avec `scale: 0.000000000931` (octets → Gio).
