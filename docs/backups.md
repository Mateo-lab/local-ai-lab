# Sauvegardes chiffrées

Outil : [restic](https://restic.net) (chiffré, dédupliqué, incrémental). Script : `scripts/backup.sh` (commande `lab backup`).

## 1. Ce qui est sauvegardé

| Élément | Méthode | Pourquoi |
|---|---|---|
| Base n8n (workflows, identifiants, historique) | `pg_dump` | copie cohérente, restaurable sur une autre version |
| Base Langfuse (si lancé) : comptes, clés API, prompts | `pg_dumpall` | idem |
| Volumes Open WebUI, n8n, Qdrant | archive `tar` du volume (conteneur `alpine` temporaire) | comptes, conversations, documents, vecteurs, clé de chiffrement de n8n |
| `ai-stack/.env`, `alerting/.env`, `monitoring/.env`, `langfuse/app/.env`, `hermes/.env`, `openclaw/.env` | copie | secrets : **sans eux, les bases restaurées sont inutilisables** (ex. `N8N_ENCRYPTION_KEY`) |
| `hermes/data`, `bench/results` | copie | historique de l'agent, mesures |

**Non sauvegardé** (se retélécharge) : modèles Ollama, images Docker, ComfyUI (modèles, cache).
Rétention : 7 quotidiennes, 4 hebdomadaires, 6 mensuelles.

Volume Qdrant et Open WebUI copiés pendant qu'ils tournent : possible incohérence si une écriture est en cours à cet
instant. Pour une copie parfaite : `lab stop` avant, `lab start` après. Les bases PostgreSQL n'ont pas ce souci.

## 2. Mise en place (une fois)

```bash
sudo apt install restic
lab backup init          # crée le dépôt /data/backups/restic et le mot de passe ~/.config/aibeast-backup/password
```
**Copie ce mot de passe tout de suite dans un gestionnaire de mots de passe, ailleurs que sur AiBeast.** Il n'y a pas
de récupération possible.
```bash
lab backup run           # première sauvegarde, à la main
lab backup list          # elle apparaît
lab backup check         # intégrité
scripts/backup.sh schedule   # (facultatif) tous les jours à 03:30
```

## 3. Limite importante : même disque

Par défaut le dépôt est sur `/data`, **le même SSD** que les données. Il protège contre une suppression par erreur, une
mise à jour qui casse une base, un conteneur corrompu. Il ne protège **pas** contre la perte du SSD, un vol, un incendie.

Copie hors-site, quand tu en auras une : `BACKUP_REPO=sftp:utilisateur@serveur:/chemin lab backup run` (restic gère
aussi S3, Backblaze B2, un disque USB monté…). Un disque USB monté sur `/mnt/usb` : `BACKUP_REPO=/mnt/usb/restic`
(`init` d'abord avec la même variable). Non testé ici.

### Copie sur le PC Windows (script exécuté et restauration testée le 2026-10-18)

Le PC tire le dépôt restic (déjà chiffré) depuis AiBeast : `windows\outils\Sauvegarder-AiBeast-hors-machine.bat` (double-clic, VPN
connecté, clé SSH chargée). Destination par défaut : `aibeast-backup\restic-repo`, à côté du dossier `windows\` (paramètre `-Destination` pour en choisir une autre).
L'emplacement du dépôt sur AiBeast est demandé à AiBeast (`lab backup repo`).
Le script :
1. lit sur AiBeast le nombre de fichiers et la taille totale du dépôt ;
2. copie par `scp` dans `restic-repo.nouveau` ;
3. compare : si les chiffres diffèrent (une sauvegarde de 03:30 tournait ?), il **ne remplace rien** ;
4. sinon garde l'ancienne copie sous `restic-repo.precedent` et installe la nouvelle ; écrit `derniere-copie.txt`.

**Décision de l'utilisateur (2026-10-18) : le fichier `password` reste dans `aibeast-backup`**, à côté de la copie, parce que
le PC est un poste d'entreprise sécurisé. Conséquence à connaître : sur ce PC, quiconque accède au dossier lit tout le
dépôt (mots de passe, `N8N_ENCRYPTION_KEY`, clés Langfuse), et la copie ne protège plus contre le vol ou l'accès du
poste. En contrepartie, la restauration depuis le PC ne dépend de rien d'autre. Si ce choix change : mettre le mot de passe
dans un gestionnaire, puis supprimer le fichier du dossier.

Pour restaurer depuis le PC : recopier `restic-repo` sur AiBeast, puis
`BACKUP_REPO=/chemin/restic-repo BACKUP_PASSWORD_FILE=... scripts/backup.sh list` (même procédure qu'au §4).
**Testé le 2026-10-18 : restauration depuis la copie du PC.** La copie `restic-repo` du PC et son fichier `password` ont été
renvoyés sur AiBeast (dans `~/restore-test`, `scp`), puis `restic restore latest --include` a extrait les deux dumps :
`n8n.sql` (568 042 octets, 157 `CREATE TABLE`) et `langfuse.sql` (314 814 octets, en-tête `PostgreSQL database cluster dump`).
La copie du PC est donc lisible avec son propre mot de passe.
Vérifié aussi : `restic snapshots` sur la copie liste les **5 mêmes instantanés** qu'AiBeast (`0a93351f`, `27f69dab`,
`5a298200`, `1c7b3a39`, `282530e8`) ; `restic check --read-data-subset=10%` : « no errors were found » (9 paquets sur 9 lus,
soit un dixième des données seulement).
Non vérifié : une lecture complète de la copie (`restic check --read-data`), le rechargement des deux dumps dans une base
(fait seulement pour Langfuse, depuis le dépôt d'origine, voir §4), et la restauration complète des volumes (Open WebUI,
n8n, Qdrant).

**Taille : 1,156 Gio le 17 octobre, 3,539 Gio le 18.** Cause probable (vue dans `restic ls`, pas mesurée au total) : Hermes a
installé des outils sous `hermes/data/installs/…/workspace/tools/` (Chromium ≈ 270 Mo, Python, Node, ffmpeg…), qui sont
sauvegardés avec le reste. Ce sont a priori des binaires re-téléchargeables par Hermes (non vérifié : à confirmer avant d'exclure quoi que ce soit). Le plus gros fichier
stable est `ai-stack_open_webui_data.tar` (1,12 Go, identique d'un jour à l'autre, donc dédupliqué par restic).
Décision en attente : exclure ces outils de la sauvegarde (gain attendu ≈ 2,4 Gio, soit l'écart constaté, sur `/data` et sur le PC), ou les garder.
À lancer à la main (ou à planifier dans le Planificateur de tâches Windows) ; la copie n'est pas automatique.

## 4. Restaurer

La restauration ne remplace **jamais** les données en place : elle les dépose dans un dossier, à toi de remettre ce qui
est nécessaire.

```bash
lab backup list                                  # repère l'ID
scripts/backup.sh restore <ID> ~/restauration    # dossier vide
ls ~/restauration/data/backups/staging ~/restauration/home/...   # n8n.sql, *.tar
```

**Base n8n** (n8n arrêté pendant l'opération) :
```bash
docker stop n8n
docker exec -i postgres-n8n psql -U n8n -d n8n < ~/restauration/data/backups/staging/n8n.sql
docker start n8n
```
**Volume** (exemple Open WebUI) :
```bash
docker stop open-webui
docker run --rm -v ai-stack_open_webui_data:/dst -v ~/restauration/data/backups/staging:/in alpine \
  sh -c 'rm -rf /dst/* /dst/.[!.]* 2>/dev/null; tar -C /dst -xf /in/ai-stack_open_webui_data.tar'
docker start open-webui
```
**Fichiers `.env`** : copie-les depuis `~/restauration/home/.../ai-lab/` vers leur emplacement d'origine.
**Langfuse** : `docker exec -i <conteneur postgres> psql -U postgres < langfuse.sql` sur une base neuve.
Test sans risque (fait le 2026-10-18) : charger `langfuse.sql` dans un PostgreSQL jetable de même image, puis compter les lignes.
```bash
IMG=$(docker inspect app-postgres-1 --format '{{.Config.Image}}')
docker run -d --rm --name pg-restore-test -e POSTGRES_PASSWORD=test "$IMG"; sleep 10
docker exec -i pg-restore-test psql -U postgres -q < ~/restore-test/.../langfuse.sql > /dev/null 2> ~/restore-test.err; echo "code : $?"
docker exec pg-restore-test psql -U postgres -d postgres -c 'select count(*) from users;' -c 'select count(*) from projects;' -c 'select count(*) from api_keys;'
docker rm -f pg-restore-test
```
Les erreurs « already exists » (rôles déjà présents dans la base neuve) sont sans gravité.

Teste une restauration **maintenant**, sur un dossier de test, avant d'en avoir besoin : une sauvegarde jamais restaurée
n'est pas prouvée.

## 5. Sauvegardes de sécurité des livraisons (`avant-*.tgz`)

`Deployer-sur-AiBeast` écrit `~/avant-AAAAMMJJ-HHMM.tgz` avant chaque extraction (≈ 1 Mo depuis le 21 octobre 2026 :
`bench/.venv` et `bench/results` sont exclus). Depuis le dépôt git, le vrai retour arrière du code est `git checkout`.
Les anciennes sauvegardes (≈ 128 Mo chacune, 17 fichiers au 21 octobre) ont été déplacées dans
`/data/backups/avant-deploiement/` (rien n'a été supprimé). Ce dossier n'est pas inclus dans restic.
Y déplacer de temps en temps les nouvelles : `mv -n ~/avant-*.tgz /data/backups/avant-deploiement/`.

## 6. Ce qui n'est pas vérifié

- Vérifié sur ta machine : sauvegarde, liste, contrôle d'intégrité, restauration de n8n, programmation quotidienne (03:30) et,
  depuis le 2026-10-18, restauration de la base Langfuse dans un PostgreSQL jetable (code 0 ; 1 utilisateur, 2 projets, 2 clés API).
- **Non vérifié** : remettre réellement une base restaurée en service (n8n ou Langfuse) ; restaurer les volumes Open WebUI/Qdrant ;
  le script de copie vers le PC Windows (§3) et une restauration depuis cette copie.
- Les chemins exacts dans l'instantané (`data/backups/staging`, `home/...`) dépendent de restic ; liste avec
  `restic ls <ID>` si besoin (`export RESTIC_REPOSITORY=… RESTIC_PASSWORD_FILE=…`).
- Le conteneur Langfuse est trouvé par le dossier de son compose (`langfuse/app`, service `postgres`), pas par le nom de projet
  (Docker le nomme `app`). Corrigé le 2026-10-17 : la première version cherchait le projet `langfuse` et ignorait la base.
- **Ce que Langfuse sauvegarde** : la base PostgreSQL (comptes, projets, clés API, prompts) et son `.env`. **Pas** ClickHouse
  (les traces elles-mêmes) ni MinIO : un suivi d'agents se reconstitue, les clés et réglages non.
- Le nom des volumes (`ai-stack_*`) suppose le nom de projet `ai-stack` (il est fixé dans le compose).
