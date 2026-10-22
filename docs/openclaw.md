# OpenClaw : installation sur AiBeast et pièges rencontrés

OpenClaw est un agent (interface web + passerelle) qui parle à ton Ollama local. Installé le 21 octobre 2026 (version **2026.10.5**), à côté de la stack, dans `~/openclaw`. Ce document garde la trace de ce qui a été fait, de ce qui a posé problème et de ce qui reste à régler.

## En bref

- Installation : `cd ~/Documents/ai-lab && ./openclaw/install.sh` (**sans** `| tee` : l'assistant a besoin d'un vrai terminal).
- Interface : `http://127.0.0.1:18789/` (tunnel SSH, port 18789), jeton `OPENCLAW_GATEWAY_TOKEN` dans `~/openclaw/.env` (ne le partage pas).
- Conteneur : `openclaw-openclaw-gateway-1` (le nom du projet Docker, `openclaw`, s'ajoute devant le nom du service).
- Modèle : `ollama/qwen3.8:27b-64k` (la version à 64 000 tokens créée par `lab dev ctx64`), contexte réellement servi : 65536.
- Configuration et données : `~/.openclaw` (vu comme `/home/node/.openclaw` dans le conteneur).

## Ce qui a été fait

1. `./openclaw/install.sh` : clone `https://github.com/openclaw/openclaw` dans `~/openclaw`, copie `docker-compose.override.yml` (la passerelle rejoint `llm-net`), puis lance l'assistant officiel `scripts/docker/setup.sh`.
2. Réponses à l'assistant : provider **Ollama**, mode **Local only**, URL `http://ollama:11434`, modèle saisi à la main ; canaux de messagerie (Discord, Telegram, WhatsApp…) : **Skip for now** ; moteur de recherche web : **Skip**. L'assistant fixe `gateway.mode=local` et `gateway.bind=lan`.
3. Clé d'API factice pour le fournisseur `ollama` (voir plus bas) : `ollama-local`.
4. Modèle par défaut fixé sur `ollama/qwen3.8:27b-64k`, et plafond de contexte `contextTokens` porté de 32768 à 65536 pour ce modèle (voir plus bas).
5. Tunnel Windows : `LocalForward 18789 127.0.0.1:18789` (présent dans la configuration générée par `lab client` ; à ajouter à la configuration SSH du PC s'il manque, puis rouvrir les tunnels).

## Problèmes rencontrés et solutions

| Symptôme | Cause | Solution |
|---|---|---|
| `Ollama could not be reached at http://ollama:11434` dans l'assistant | Le script officiel appelle `docker compose -f docker-compose.yml …` : en désignant ce fichier, Docker **ignore** `docker-compose.override.yml`, donc la passerelle et le conteneur de l'assistant ne rejoignent pas `llm-net` | `docker network connect llm-net openclaw-openclaw-gateway-1` (et pour le conteneur temporaire de l'assistant : `docker network connect llm-net $(docker ps --format '{{.Names}}' \| grep 'openclaw-openclaw-gateway-run' \| head -1)`) ; `install.sh` le fait désormais après l'assistant |
| `docker exec openclaw-gateway …` : « No such container » | Le vrai nom est `openclaw-openclaw-gateway-1` | Utiliser ce nom, ou `docker compose -f ~/openclaw/docker-compose.yml exec openclaw-gateway …` |
| La passerelle redémarre en boucle (`Up 5 seconds`) ; journal : « Gateway start blocked: existing config is missing gateway.mode » | Configuration incomplète laissée par un premier essai qui avait échoué | `docker compose stop openclaw-gateway`, puis relancer l'installation ; l'assistant remet `gateway.mode=local` |
| « Onboarding needs an interactive TTY » | L'installation avait été lancée avec `\| tee`, ce qui retire le terminal | Relancer sans `tee` (pour garder une trace : `script -q -c "./openclaw/install.sh" /tmp/openclaw-install.log`) |
| « AI access test failed: No API key found for provider "ollama" » | OpenClaw exige une clé même pour Ollama local | `docker exec -it openclaw-openclaw-gateway-1 openclaw models auth paste-api-key --provider ollama`, valeur factice `ollama-local` ; puis `docker restart openclaw-openclaw-gateway-1` |
| Premier message : `401 Unauthorized` sur **`https://api.openai.com/v1/responses`** | Le chat utilisait un modèle OpenAI, pas Ollama (le défaut enregistré était `ollama/gemma4`, et le sélecteur du chat avait un autre modèle) | `models set ollama/qwen3.8:27b-64k`, modèle choisi dans les réglages de l'interface, aucun modèle de repli. Le message de test a quitté la machine mais a été refusé faute de clé |
| `ollama ps` affiche CONTEXT 32768 alors que le modèle a `num_ctx 65536` | OpenClaw enregistre pour chaque modèle un plafond `contextTokens` (32768) qu'il envoie à Ollama, et qui l'emporte sur le réglage du modèle | Modifier `contextTokens` du modèle dans `~/.openclaw/openclaw.json` (passerelle arrêtée, sauvegarde `openclaw.json.avant-64k`) ; contrôle : `ollama ps` après un message affiche `65536` |
| Erreurs de fin d'installation (« different PID namespace », « Failed to reset agents.defaults.sandbox.mode to off ») | Un conteneur temporaire lit la configuration pendant que la passerelle la verrouille | Sans effet constaté sur le fonctionnement ; l'état du bac à sable des outils n'a pas été vérifié |
| Page inaccessible depuis Windows | Le tunnel SSH ouvert n'avait pas la redirection du port 18789 | Ajouter `LocalForward 18789 127.0.0.1:18789`, fermer et rouvrir les tunnels ; test : `Test-NetConnection 127.0.0.1 -Port 18789` |

## Réglages qui comptent

- **Modèle par défaut** (CLI, depuis `~/openclaw`) :
  ```
  docker compose -f docker-compose.yml exec openclaw-gateway sh -lc 'node dist/index.js models status'
  docker compose -f docker-compose.yml exec openclaw-gateway sh -lc 'node dist/index.js models set ollama/qwen3.8:27b-64k'
  ```
  Après un changement : `docker restart openclaw-openclaw-gateway-1`, puis vérifier que `llm-net` contient bien `ollama` et `openclaw-openclaw-gateway-1`.
- **Ne connecte aucun compte de modèle hébergé** (bandeau « Connect a verified AI model ») : cela lierait un service extérieur. « Allowed models » est sur « all » : un modèle d'un autre fournisseur reste sélectionnable à la main ; une restriction n'a pas été faite.
- **Thinking** : réglé sur « Default » ; les modèles Qwen peuvent réfléchir longuement avant de répondre. « Off » accélère les réponses.
- **VRAM** : la version 64k occupe ≈ 21 Go (cache KV en q8_0). Ne pas laisser ComfyUI tourner en même temps (`lab mode normal`).

## Sécurité : à traiter

- **Ports exposés à tout le réseau.** `ss -tlnp | grep -E '18789|3978'` montre `0.0.0.0` et `[::]` pour les deux ports (18789 : interface, 3978 : service des canaux de messagerie). Le compose officiel les publie sur toutes les interfaces et l'installation fixe `gateway.bind=lan`. Seul le jeton protège la passerelle depuis le réseau local ou le VPN. À restreindre à `127.0.0.1` (ou par pare-feu `DOCKER-USER`).
- **59 outils** (journal : `cataloged 59 tools`). Je n'ai pas vu la liste ni l'état du bac à sable : ne pas confier à l'agent de tâches qui lisent ou écrivent des fichiers ou lancent des commandes avant de les avoir relus dans l'interface.
- **Aucun canal de messagerie** n'est configuré (volontaire) : tout ce qui arrive de l'extérieur peut donner des instructions à un agent.
- Le message de test parti vers OpenAI (refusé) montre qu'un mauvais réglage du modèle peut envoyer ce que tu écris à un service extérieur : après toute modification, vérifier le modèle actif.

## Mise à jour

`cd ~/openclaw && git pull && docker compose pull && docker compose up -d`, puis **rattacher à nouveau** la passerelle à Ollama (`docker network connect llm-net $(docker compose -f docker-compose.yml ps -q openclaw-gateway)`) : une recréation du conteneur fait perdre le rattachement. Relancer `./openclaw/install.sh` le refait aussi.

## Ce qui n'est pas vérifié

- **La qualité des réponses** d'OpenClaw avec ce modèle n'a pas été jugée ; seul le fonctionnement (`chat.send`, réponse en ≈ 11 s au premier message) a été constaté dans les journaux.
- **`contextTokens`** : l'interprétation (plafond envoyé à Ollama) est une déduction ; elle est confortée par `ollama ps` (65536 après modification) mais pas par la documentation d'OpenClaw. La modification a été faite directement dans `openclaw.json` ; je ne sais pas si une mise à jour ou la redécouverte des modèles la remet à 32768. Si c'est le cas, passer par la commande `config` de la CLI (non explorée).
- La **mémoire sémantique** est dégradée (`memory_index_chunks_vec not updated — semantic vector embeddings unavailable`) : aucun modèle d'embeddings n'est configuré. Non traité.
- **Les ports 18789 et 3978** restent ouverts sur toutes les interfaces : correctif non écrit ni testé.
- **Bac à sable et outils** : état non vérifié (voir plus haut).
- Le correctif de `install.sh` (rattachement automatique à `llm-net`) a été écrit mais **pas exécuté** ; la syntaxe a été contrôlée (`bash -n`).
- Le dossier `~/openclaw` et `~/.openclaw` contiennent des identifiants (jeton de la passerelle) : ils ne sont pas inclus dans les sauvegardes décrites par `docs/sauvegardes.md` (non vérifié).
