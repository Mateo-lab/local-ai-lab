# Isolation réseau des agents (Hermes, OpenClaw)

Objectif : un agent peut être manipulé par ce qu'il lit (injection de prompt) ou mal réglé (le premier message de test
d'OpenClaw est parti vers `api.openai.com`, voir [openclaw.md](openclaw.md)). On lui retire donc tout accès réseau
dont il n'a pas besoin : **ni Internet, ni le réseau local, ni la machine IA elle-même**. Il ne garde que le modèle
local (Ollama), le suivi (Langfuse), et, pour Hermes, SSH vers les machines de test que tu as explicitement autorisées.

## 1. Ce que chaque agent peut joindre

| Destination | Hermes | OpenClaw |
|---|---|---|
| Ollama (`http://ollama:11434`) | oui (réseau `hermes-net`) | oui (réseau `llm-net`) |
| Langfuse (`http://langfuse-web:3000`) | oui (réseau `obs-net`) | non |
| Machines de test de `LAB_AGENT_SSH_ALLOW` (SSH) | oui, ces adresses et ports seulement | non |
| Internet | **non** | **non** |
| Réseau local, VPN, autres machines | **non** | **non** |
| La machine IA elle-même (SSH, bureau à distance, ports de services) | **non** | **non** |
| Son interface web depuis ton PC (tunnel SSH) | sans objet | oui (`127.0.0.1:18789`, connexion entrante) |

Ollama, Open WebUI, SearXNG, n8n… ne sont pas concernés : ils gardent leur accès normal (téléchargement de modèles,
recherche web), par le réseau `ai-net`.

## 2. Comment c'est fait

Deux mécanismes complémentaires :

1. **Réseaux Docker « internes »** (`ai-stack/docker-compose.yml`) : `llm-net`, `hermes-net` et `obs-net` ont
   `internal: true`. Docker ne leur donne aucune route vers l'extérieur ; les conteneurs reliés ne s'y parlent
   qu'entre eux. Ollama et Open WebUI, reliés aussi à `ai-net`, sortent par celui-ci.
2. **Pare-feu** (`scripts/isolation-agents.sh`, commande `lab isolation`) pour les deux réseaux qui ne peuvent pas être
   internes :
   - `hermes-sortie` (interface `br-hermes-out`, `hermes/docker-compose.yml`) : la seule route de Hermes vers
     l'extérieur. Tout y est bloqué sauf les adresses de `LAB_AGENT_SSH_ALLOW` (TCP, port 22 par défaut).
   - `openclaw_default` (créé par le compose officiel d'OpenClaw) : nécessaire pour publier l'interface web. Toute
     connexion **sortante** y est bloquée ; les connexions **entrantes** (ton tunnel) et leurs réponses passent.

   Les règles sont dans deux chaînes iptables : `AI-LAB-AGENTS` (appelée par `DOCKER-USER`, trafic qui traverse la
   machine) et `AI-LAB-AGENTS-HOTE` (appelée par `INPUT`, trafic vers la machine elle-même, bloqué depuis les réseaux
   des agents sauf réponses). Les paquets bloqués sont journalisés (au plus 6 par minute) avec le préfixe
   `ai-lab agent bloque:` : `sudo journalctl -k | grep "ai-lab agent"`.

Le service systemd `ai-lab-isolation` réapplique les règles à chaque démarrage de Docker.

## 3. Mise en place

1. Dans `lab.conf`, les machines de test que Hermes doit pouvoir joindre en SSH (sinon, laisser vide) :
   ```
   LAB_AGENT_SSH_ALLOW="192.168.1.60"            # plusieurs : "192.168.1.60 192.168.1.61:2222"
   ```
2. Réseaux internes : sur une **nouvelle** installation, rien à faire (`./3-demarrer.sh` les crée ainsi). Sur une
   installation **existante**, Docker ne modifie pas un réseau déjà créé : il faut le recréer (§6).
3. Pare-feu :
   ```bash
   lab isolation install     # service systemd + application immédiate (demande sudo)
   lab isolation test        # vérifie depuis les conteneurs
   ```
4. `lab doctor` contrôle ensuite que les trois réseaux sont internes et que le service est actif.

## 4. Vérifier : `lab isolation test`

Le test ouvre de vraies connexions depuis l'intérieur des conteneurs et compare au résultat attendu :

| Contrôle | Attendu |
|---|---|
| Ollama (`ollama:11434`) | joignable |
| Internet (`1.1.1.1:443`, `example.com:443`) | bloqué |
| La machine IA (son adresse sur le réseau, et son adresse sur le réseau Docker), port 22 | bloqué |
| Chaque machine de `LAB_AGENT_SSH_ALLOW` (Hermes) | joignable (si elle est allumée et que SSH y tourne) |

Pour Hermes, le test lance un conteneur temporaire (`docker compose run --rm`) avec `python3` ; pour OpenClaw, il
s'exécute dans la passerelle avec `node`. `lab isolation status` affiche les règles et le nombre de paquets bloqués.

## 5. Conséquences à connaître

- **Hermes** : plus de recherche web, de téléchargement de paquets (`pip`, `npm`), d'outils navigateur, ni
  d'installation de plugin depuis Internet (par exemple `plugins install langfuse`). Pour une installation ponctuelle :
  `lab isolation remove`, l'installation, puis `lab isolation apply` aussitôt après. `hermes-net` et `obs-net`
  restent internes pendant ce temps : seule la route `hermes-sortie` est ouverte.
- **OpenClaw** : plus de recherche web, de canaux de messagerie (Discord, Telegram…), ni de modèle hébergé, même
  sélectionné par erreur : la requête est bloquée avant de quitter la machine.
- **Mises à jour** : les images et le code (`docker pull`, `git pull`) sont téléchargés par la machine, pas par les
  agents : elles continuent de marcher.
- **OpenClaw recréé** (mise à jour, `docker compose down`) : son réseau peut changer d'identifiant. `openclaw/install.sh`
  réapplique les règles ; sinon `lab isolation apply`. `lab isolation status` signale un réseau non couvert.

## 6. Passer une installation existante en réseaux internes

Les réseaux `llm-net`, `hermes-net` et `obs-net` doivent être supprimés puis recréés. Les **données ne sont pas
touchées** (elles sont dans les volumes) ; les services concernés redémarrent (≈ 1 minute) : Ollama, Open WebUI et le
reste d'`ai-stack`, la passerelle OpenClaw, le portail, Langfuse s'il tourne.

```bash
cd ~/Documents/ai-lab
# 1. Arrêter et retirer les conteneurs reliés à ces réseaux (SANS -v : les volumes et les données restent)
(cd ~/openclaw 2>/dev/null && docker compose -f docker-compose.yml down)
[ -f langfuse/app/docker-compose.yml ] && (cd langfuse/app && docker compose down)
(cd portail && docker compose down)
(cd ai-stack && docker compose down)           # supprime aussi llm-net, hermes-net, obs-net
docker network ls | grep -E 'llm-net|hermes-net|obs-net' && echo "un réseau reste : voir ci-dessous" || echo "réseaux supprimés"
# 2. Tout recréer : les réseaux reviennent en « internes »
lab start
(cd ~/openclaw && docker compose -f docker-compose.yml up -d openclaw-gateway && docker network connect llm-net openclaw-openclaw-gateway-1)
# 3. Pare-feu, puis vérification
lab isolation install && lab isolation test && lab doctor
```

Si un réseau reste (`docker network ls`), un conteneur y est encore relié :
`docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' NOM_DU_RESEAU`, arrêter ce conteneur, puis
`docker network rm NOM_DU_RESEAU`.

**Jamais `docker compose down -v`** : `-v` supprimerait les volumes (modèles, conversations, workflows).

## 7. Revenir en arrière

- Pare-feu seul : `lab isolation uninstall`.
- Réseaux : retirer les trois lignes `internal: true` d'`ai-stack/docker-compose.yml` et refaire §6.

## Ce qui n'est pas vérifié

- L'ensemble a été écrit et testé hors de la machine (syntaxe, sondes de test) ; il n'a pas encore été appliqué sur
  une vraie installation au moment de cette rédaction.
- Que l'image de Hermes contienne `python3` à cet emplacement (sinon `lab isolation test` échoue pour Hermes sans
  que l'isolation soit en cause).
- Le comportement de l'assistant d'installation d'OpenClaw (`setup.sh`) quand l'isolation est déjà active : s'il a
  besoin d'Internet, désactiver le temps de l'installation (`lab isolation remove`).
- IPv6 n'est pas filtré : les réseaux Docker du lab n'ont pas d'IPv6 activé. Si tu l'actives, ces règles ne suffisent
  plus.
- Les règles visent le pare-feu iptables de Docker (cas d'Ubuntu par défaut) ; avec le pare-feu nftables natif de
  Docker, elles ne s'appliqueraient pas.
