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
   installation **existante**, Docker ne modifie pas un réseau déjà créé : il faut le recréer (§7).
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

## 5. La machine de test (lien SSH de Hermes)

Le pare-feu d'AiBeast laisse Hermes ouvrir SSH vers les machines de `LAB_AGENT_SSH_ALLOW`. Par ce lien, Hermes
pourrait encore joindre Internet de deux façons ; les deux sont fermées :

| Chemin | Protection |
|---|---|
| **Tunnel SSH** (redirection de port `-L`, proxy SOCKS `-D`, `-W`) à travers la machine de test | Option `restrict` sur la clé de Hermes (posée par `lab remote add`) **et**, côté serveur SSH, pour son compte : `AllowTcpForwarding no`, `AllowStreamLocalForwarding no`, `PermitTunnel no`, `AllowAgentForwarding no`, `X11Forwarding no`, `GatewayPorts no` (une redirection inverse `-R` ne peut pas s'ouvrir au réseau de la machine ; déjà exclue par `AllowTcpForwarding no`, gardée en double protection) |
| **Commandes lancées sur la machine de test** (PowerShell, `curl`…) qui sortent par sa connexion | Internet coupé pour **toute** la machine par son pare-feu : règles de blocage sortant vers toutes les adresses publiques (IPv4 et IPv6) et du DNS (port 53, qui permettrait de faire sortir des données par des requêtes à la box). Le réseau local reste joignable |

Pourquoi toute la machine ? Le pare-feu de Windows ne sait pas bloquer Internet pour un seul compte local
(le filtrage par utilisateur ne vaut que pour du trafic authentifié par IPsec) : seule une règle pour toute la
machine est fiable. Un compte sans droits d'administrateur, comme celui de Hermes, ne peut pas la modifier.

**Mise en place**, sur la machine de test Windows, dans PowerShell **en administrateur**, avec le fichier
`windows\outils\Isoler-machine-de-test.ps1` copié sur cette machine :

```powershell
powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1            # compte de l'agent : hermes
powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1 -Annuler   # rendre Internet à la machine
```

Le script sauvegarde la configuration du pare-feu et `sshd_config` (dans `C:\ProgramData\ssh`), pose les règles
(groupe « local-ai-lab isolation »), ajoute les options SSH au bloc `Match User hermes` (vérifié par `sshd -t`,
version précédente remise en cas d'erreur), puis vérifie qu'Internet et le DNS sont bloqués.

**Vérification depuis AiBeast**, avec les yeux de Hermes : `lab remote test NOM`. Lignes attendues :
`tunnel SSH refusé : bien`, `Internet depuis la machine : bloqué, bien`, `DNS depuis la machine : bloqué, bien`.

**Conséquences** : plus d'Internet pour personne sur cette machine (mises à jour Windows comprises). Pour une mise à
jour : `-Annuler`, la mise à jour, puis relancer le script. Si la machine de test n'est joignable que par un client VPN
installé sur elle-même, ce client ne pourra plus se connecter : vérifier avant.

## 6. Conséquences à connaître

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

## 7. Passer une installation existante en réseaux internes

Les réseaux `llm-net`, `hermes-net` et `obs-net` doivent être supprimés puis recréés. Les **données ne sont pas
touchées** (elles sont dans les volumes, et ce que Hermes conserve est dans `hermes/data`) ; les services concernés
redémarrent (≈ 1 minute) : `ai-stack` (Ollama, Open WebUI…), le portail, Langfuse, la passerelle OpenClaw.

Piège rencontré sur la machine de référence : des **sessions Hermes orphelines** (conteneurs `hermes-hermes-run-…`
restés en marche des jours après la fermeture de leur terminal) bloquaient la suppression des réseaux. Le script
ci-dessous les retire, puis vérifie chaque étape et **s'arrête** au premier problème. Coller tout le bloc :

```bash
bash <<'EOF'
set -euo pipefail
cd ~/Documents/ai-lab
interne() { [ "$(docker network inspect -f '{{.Internal}}' "$1" 2>/dev/null)" = true ]; }
echo "1. Sessions Hermes encore en marche (hermes/data n'est pas touché)"
docker ps -a --filter name=hermes-hermes-run --format '   {{.Names}}  {{.Status}}'
docker ps -aq --filter name=hermes-hermes-run | xargs -r docker rm -f
echo "2. Arrêt de ce qui est relié aux réseaux (SANS -v : volumes et données restent)"
(cd ~/openclaw 2>/dev/null && docker compose -f docker-compose.yml down) || true
[ ! -f langfuse/app/docker-compose.yml ] || (cd langfuse/app && docker compose down)
(cd portail && docker compose down)
(cd ai-stack && docker compose down)
echo "3. Suppression des réseaux non internes"
for n in llm-net hermes-net obs-net; do
  if docker network inspect "$n" >/dev/null 2>&1 && ! interne "$n"; then
    docker network rm "$n" || { echo "ARRÊT : $n encore utilisé par : $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$n")"; exit 1; }
  fi
done
echo "4. Redémarrage"
lab start
for n in llm-net hermes-net obs-net; do interne "$n" || { echo "ARRÊT : $n n'est pas interne"; exit 1; }; done
[ -n "$(docker ps -q --filter name=^ollama$)" ] || { echo "ARRÊT : Ollama ne tourne pas (lab logs ollama)"; exit 1; }
if [ -d ~/openclaw ]; then
  (cd ~/openclaw && docker compose -f docker-compose.yml up -d --force-recreate openclaw-gateway)
  docker network connect llm-net openclaw-openclaw-gateway-1 2>/dev/null || true
fi
echo "5. Pare-feu et vérification"
if systemctl is-active --quiet ai-lab-isolation.service; then lab isolation apply; else lab isolation install; fi
lab isolation test
lab doctor | tail -9
EOF
```

Si un `ARRÊT` apparaît, rien d'autre n'est fait après ce point ; `lab start` relance les services sur les réseaux
existants (sans isolation) le temps de corriger.

**Jamais `docker compose down -v`** : `-v` supprimerait les volumes (modèles, conversations, workflows).

## 8. Revenir en arrière

- Pare-feu seul : `lab isolation uninstall`.
- Réseaux : retirer les trois lignes `internal: true` d'`ai-stack/docker-compose.yml` et refaire §7.

## Ce qui n'est pas vérifié

- **Vérifié le 22 octobre 2026 sur la machine de référence** (Docker 29.9, iptables) : `lab isolation test` réussit
  pour OpenClaw et Hermes (Ollama joignable ; Internet par IP et par nom bloqué ; machine hôte bloquée ; machine de
  test autorisée joignable en SSH). Le script du §7 est la version corrigée après le premier passage (sessions
  Hermes orphelines) : sa forme complète n'a pas été rejouée.
- Le redémarrage de la machine (réapplication des règles par le service systemd) n'a pas encore été observé.
- Le comportement de l'assistant d'installation d'OpenClaw (`setup.sh`) quand l'isolation est déjà active : s'il a
  besoin d'Internet, désactiver le temps de l'installation (`lab isolation remove`).
- IPv6 n'est pas filtré : les réseaux Docker du lab n'ont pas d'IPv6 activé. Si tu l'actives, ces règles ne suffisent
  plus.
- **Machine de test : vérifié le 22 octobre 2026** sur la machine Windows de référence, avec `lab remote test` :
  tunnel SSH refusé, Internet et DNS bloqués depuis la machine, connexion SSH de l'agent toujours possible. Avant le
  script, le même test montrait `internet=True dns=True`.
- Les règles visent le pare-feu iptables de Docker (cas d'Ubuntu par défaut) ; avec le pare-feu nftables natif de
  Docker, elles ne s'appliqueraient pas.
