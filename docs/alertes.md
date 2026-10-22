# Alertes : être prévenu avant de constater la panne

Projet : `alerting/` (démarré par `lab start`). Chaîne complète :

```
blackbox-exporter ──(sondes HTTP)──┐
node-exporter / gpu-exporter ──────┼──> Prometheus ──(règles)──> Alertmanager ──> alertmanager-ntfy ──> ntfy ──> navigateur / téléphone
                                   │    monitoring/prometheus/rules/alertes.yml
```

## 1. Ce qui est surveillé

| Alerte | Condition | Durée | Gravité |
|---|---|---|---|
| `ServiceInjoignable` | une sonde HTTP échoue (Open WebUI, n8n, Qdrant, Ollama, SearXNG, Kokoro, Tika, Grafana) | 3 min | critique |
| `ExporterInjoignable` | Prometheus ne reçoit plus node-exporter ou gpu-exporter | 2 min | avertissement |
| `DisqueDataPresquePlein` | tout disque ext4/xfs/btrfs sauf `/` (aujourd'hui : `/data`) > 85 % | 10 min | avertissement |
| `DisqueSystemePresquePlein` | `/` > 85 % | 10 min | avertissement |
| `MemoireVive` | RAM > 92 % | 10 min | avertissement |
| `GpuTropChaud` | GPU > 85 °C | 5 min | critique |
| `GpuBloqueEnP2AuRepos` | P-state < 8 et utilisation < 5 % | 30 min | avertissement |

La dernière règle détecte le problème du 15 octobre (GPU à ≈ 124 W sans rien faire, voir `remote-desktop-gpu.md`).
Les seuils sont des choix raisonnables, pas des mesures : ajuste-les dans `monitoring/prometheus/rules/alertes.yml`
(puis `docker restart prometheus`).

Pas surveillé : Langfuse, ComfyUI, Hermes (pas de sonde ajoutée ; ComfyUI et Hermes sont éteints par défaut, une alerte
serait un faux positif permanent). Pour ajouter une sonde : une ligne dans `targets` du job `sondes` de
`monitoring/prometheus/prometheus.yml`.

## 2. Démarrer

```bash
lab start                 # démarre tout, dans l'ordre (ai-stack, monitoring, portail, alerting)
docker restart prometheus # une seule fois, si monitoring tournait déjà : il relit les règles
```
**Changement de réseau Docker à connaître.** Le réseau de `monitoring` s'appelait `monitoring_mon-net` (nom automatique)
alors que `portail/` et `alerting/` le désignent par `mon-net`. Il porte maintenant ce nom fixe. Au prochain
`docker compose up -d` dans `monitoring/`, Docker recrée ce réseau et les conteneurs de monitoring (les données
Prometheus/Grafana sont dans des volumes : conservées). Ne jamais utiliser `down -v`.

Contrôles :
1. `http://127.0.0.1:9090/rules` : les trois groupes (services, machine, gpu) doivent apparaître.
2. `http://127.0.0.1:9090/targets` : jobs `sondes` et `blackbox` en `UP`.
3. `http://127.0.0.1:9093` : Alertmanager répond.

## 3. Recevoir les notifications

Le « sujet » ntfy est `aibeast-alertes` (`alerting/alertmanager-ntfy/config.yml`).

- **Sur le PC Windows** (tunnels ouverts) : ouvre `http://127.0.0.1:2586/aibeast-alertes`, clique sur l'icône cloche
  pour autoriser les notifications du navigateur.
- **Test sans attendre une panne** (sur AiBeast) :
  `curl -d "test d'alerte" http://127.0.0.1:2586/aibeast-alertes` : le message doit apparaître. Cela teste ntfy seul.
- **Test de la chaîne complète** : `docker stop searxng`, attends ≈ 4 min (3 min de durée + 30 s de regroupement) →
  notification « searxng:8080 ne répond plus » ; `docker start searxng` → notification de retour à la normale.
- **Sur téléphone** : l'application ntfy peut s'abonner à un serveur auto-hébergé, mais le port est lié à `127.0.0.1`.
  Pour qu'un téléphone connecté au VPN l'atteigne, mets dans `alerting/.env` `NTFY_BIND=<IP d'AiBeast sur le VPN>`
  et `NTFY_BASE_URL=http://<cette IP>:2586`, et `NTFY_AUTH_DEFAULT_ACCESS=deny-all` (puis crée un compte avec
  `docker exec -it ntfy ntfy user add --role=admin TON_NOM`). Sur Android l'abonnement à un serveur en `http` fonctionne ;
  sur iOS les notifications passent par le service ntfy.sh, ce qui demande une configuration supplémentaire
  (`upstream-base-url`) non faite ici.

## 4. Que faire quand une alerte arrive

| Alerte | Premier geste |
|---|---|
| `ServiceInjoignable` | `lab status`, puis `lab logs <service>` ; `docker restart <service>` |
| `DisqueDataPresquePlein` | `lab doctor`, `docker system df`, anciens résultats dans `bench/results/` |
| `DisqueSystemePresquePlein` | `sudo journalctl --vacuum-size=200M`, `sudo apt clean` |
| `GpuTropChaud` | ventilation, poussière ; `lab gpu-limit install 300` |
| `GpuBloqueEnP2AuRepos` | `nvidia-smi` ; `lab bureau off` depuis une session SSH |
| `ExporterInjoignable` | `docker ps` ; `lab logs gpu-exporter` |

## 5. Ce qui n'est pas vérifié

- **Vérifié le 16 octobre 2026** : la chaîne complète (sonde → règle `ServiceInjoignable` → Alertmanager → pont →
  ntfy → navigateur), y compris le message « Résolu » au redémarrage de searxng. Le message arrive avec le titre, le
  texte et les étiquettes prévus.
- **Pas vérifié** : les six autres règles (disques, RAM, température, GPU bloqué en P2, exporters) n'ont jamais été
  déclenchées ; leur syntaxe est contrôlée, pas leur seuil réel ni l'existence de toutes les métriques.
- Pont `ghcr.io/alexbakker/alertmanager-ntfy` : l'image, la commande (`--configs`), le port 8000 et l'URL `/hook` sont
  **vérifiés** (alerte reçue le 16 octobre 2026). Une première configuration trop courte (seulement `topic`) faisait
  planter le pont (`nil pointer dereference` dans `forwardAlert`, réponse 500 à Alertmanager) : il faut aussi définir
  `priority`, `tags` et `templates`, comme dans le fichier fourni. Plan B si le pont pose problème : un récepteur webhook
  de ton choix (n8n sait en recevoir un et appeler ntfy).
- Le sujet `aibeast-alertes` contient un tiret ; le pont accepte une expression pour `topic`. Si les messages n'arrivent
  pas sous ce nom, essaie un sujet sans tiret (à changer aussi dans l'URL de lecture).
- Les noms de métriques `nvidia_smi_*` : `nvidia_smi_pstate` (nombre de 0 à 15) et `nvidia_smi_utilization_gpu_ratio`
  (0 à 1) sont supposés ; la fiche du portail les utilise aussi. Vérifie-les dans `http://127.0.0.1:9090/graph`.
  Si l'une manque, la règle ne se déclenche jamais, sans erreur.
- Les disques sont vus par node-exporter via `/:/host:ro,rslave` ; un disque de données absent de
  `node_filesystem_size_bytes` (autre système de fichiers que ext4/xfs/btrfs, par exemple) n'est pas surveillé.
- Les sondes comptent un code 401/403 comme « vivant ».
