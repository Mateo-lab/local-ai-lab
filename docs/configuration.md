# Configuration propre à la machine (`lab.conf`)

Objectif : installer le lab sur n'importe quelle machine sans modifier les scripts. **`lab.conf` est le seul fichier
à adapter** (procédure complète : [installation.md](installation.md)).
Trois catégories de fichiers sont séparées :

| Catégorie | Exemples | Dans git ? |
|---|---|---|
| Code (identique partout) | `lab`, `scripts/`, `*.sh`, compose, `docs/` | oui |
| Configuration de la machine | `lab.conf`, `windows/ssh_config_aibeast.txt` (généré par `lab client`) | non (`lab.conf.example`, `windows/ssh_config_aibeast.example` oui) |
| Secrets et données | `**/.env`, `client_secret*`, clés, `hermes/data/`, `bench/results/` | jamais |

## Mise en place

    cp lab.conf.example lab.conf
    nano lab.conf

`lab.conf` est lu par bash : uniquement des lignes `NOM=valeur`, sans espace autour du `=`.
Aucun mot de passe ni clé dans ce fichier : les secrets restent dans les `.env`.
Sans `lab.conf`, les valeurs par défaut s'appliquent.

## Variables

| Variable | Défaut | Utilisée par |
|---|---|---|
| `LAB_DATA_DIR` | `/data` | `lab status`, `lab doctor`, `scripts/backup.sh` (dépôt restic, zone de staging, unité systemd), `8-stockage.sh` |
| `LAB_MODEL` | aucun | `lab` (prioritaire sur `lab config set MODEL`), `3-demarrer.sh` sans argument, `n8n/build.py` |
| `LAB_HOST` | aucun (obligatoire pour `lab client`) | `lab client` : adresse de la machine IA vue par ton PC (IP locale, IP VPN, nom Tailscale) |
| `LAB_USER` | l'utilisateur qui lance `lab client` | `lab client` : compte Linux pour SSH |
| `LAB_SSH_PORT` | `22` | `lab client` |
| `LAB_SSH_KEY` | `~/.ssh/id_ed25519` | `lab client` : clé privée **sur le PC** |
| `LAB_RDP_LOCAL_PORT` | `13389` | `lab client` : port local du tunnel vers le bureau à distance (3389 de la machine IA) |

Remarques :

- L'alerte `DisqueDataPresquePlein` (Prometheus) et la tuile « Disque données » du portail surveillent tous les disques
  ext4, xfs ou btrfs sauf `/` : elles ne dépendent pas de `LAB_DATA_DIR`.
- Machine à un seul disque : mets `LAB_DATA_DIR` sur un dossier du disque système ; `lab doctor` affiche alors une
  remarque (`!`) au lieu d'une erreur.
- Les scripts Windows n'ont plus de chemin en dur : l'archive et la copie des sauvegardes sont cherchées à côté du
  dossier `windows\`, et l'emplacement du dépôt restic est demandé à la machine IA (`lab backup repo`).
- `BACKUP_REPO` et `BACKUP_STAGE` restent prioritaires sur `LAB_DATA_DIR` pour les sauvegardes.
- Le timer de sauvegarde déjà installé garde son fichier systemd. Après un changement de
  `LAB_DATA_DIR`, relancer `lab backup schedule` pour le réécrire.
- `n8n/build.py` lit la variable d'environnement, pas `lab.conf` :
  `cd n8n && LAB_MODEL=nom:tag python3 build.py`. Sans variable : `qwen3.8:27b`.
  Chaque exécution change les identifiants aléatoires des JSON (diff git bruyant, sans effet).

## Valeurs fixes (identiques sur toutes les installations)

- Le nom du raccourci SSH `aibeast`, utilisé par tous les scripts de `windows/`.
- Les ports des interfaces (tous sur `127.0.0.1`) : changer un port demande de modifier le compose concerné et la
  liste des tunnels de `scripts/client-config.sh`.
- Le dossier du projet n'est pas imposé, mais les scripts Windows supposent `lab install` fait (`~/.local/bin/lab`).

## État des tests (21 octobre 2026)

| Élément | Testé |
|---|---|
| `lab doctor` sans `lab.conf` | oui, identique à avant |
| `LAB_DATA_DIR=/tmp lab doctor` | oui, la variable est lue |
| `lab backup last` et `8-stockage.sh etat` | oui, avec la valeur par défaut seulement |
| `n8n/build.py` avec `LAB_MODEL` | oui, dans un dossier temporaire |
| `3-demarrer.sh` avec `LAB_MODEL` | non, syntaxe seulement (le lancer redémarre la stack) |
| `lab client` (génération, refus sans `LAB_HOST`, refus d'une valeur avec caractère spécial) | oui, hors machine de référence |
| Scripts Windows sans chemin en dur, tuile disque du portail | non (écrits, pas exécutés) |
| Installation complète avec un `lab.conf` réel sur une autre machine | non |

## Git

Le dossier du projet est un dépôt git. Le dépôt public est publié avec un historique neuf, sans les valeurs
personnelles de la machine d'origine.
Avant tout `git add`, vérifier qu'aucun secret n'est ajouté :

    git add -n . | grep -iE "\.env$|secret|\.key|\.pem|/id_"
    git check-ignore -v ai-stack/.env lab.conf

Revenir sur un fichier : `git checkout -- FICHIER`. Historique : `git log --oneline`.

## Ce qui n'est pas vérifié

- Un `lab.conf` réel avec `LAB_DATA_DIR` différent de `/data` (seul un test temporaire `LAB_DATA_DIR=/tmp lab doctor` a été fait).
- `3-demarrer.sh` sans argument avec `LAB_MODEL` défini (non lancé : il redémarre la stack).
- La réécriture de l'unité systemd par `lab backup schedule` avec un autre `LAB_DATA_DIR`.
- Une installation complète sur une autre machine.
