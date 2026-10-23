# Encrypted backups

Tool: [restic](https://restic.net) (encrypted, deduplicated, incremental). Script: `scripts/backup.sh` (`lab backup`
command).

## 1. What is backed up

| Item | Method | Why |
|---|---|---|
| n8n database (workflows, credentials, history) | `pg_dump` | consistent copy, restorable on another version |
| Langfuse database (if running): accounts, API keys, prompts | `pg_dumpall` | same |
| Open WebUI, n8n, Qdrant volumes | `tar` archive of the volume (temporary `alpine` container) | accounts, conversations, documents, vectors, n8n encryption key |
| `ai-stack/.env`, `alerting/.env`, `monitoring/.env`, `langfuse/app/.env`, `hermes/.env`, `openclaw/.env` | copy | secrets: **without them, the restored databases are useless** (e.g. `N8N_ENCRYPTION_KEY`) |
| `hermes/data`, `bench/results` | copy | agent history, measurements |

**Not backed up** (can be downloaded again): Ollama models, Docker images, ComfyUI (models, cache).
Retention: 7 daily, 4 weekly, 6 monthly.

The Qdrant and Open WebUI volumes are copied while running: possible inconsistency if a write is in progress at that
moment. For a perfect copy: `lab stop` before, `lab start` after. The PostgreSQL databases do not have this problem.

## 2. Setup (once)

```bash
sudo apt install restic
lab backup init          # creates the repository /data/backups/restic and the password ~/.config/aibeast-backup/password
```
**Copy this password right away into a password manager, somewhere other than the AI machine.** There is no way to
recover it.
```bash
lab backup run           # first backup, by hand
lab backup list          # it appears
lab backup check         # integrity
lab backup schedule      # (optional) every day at 03:30
```

## 3. Important limit: same disk

By default the repository is on `/data`, **the same SSD** as the data. It protects against an accidental deletion, an
update that breaks a database, a corrupted container. It does **not** protect against losing the SSD, theft, fire.

Off-site copy, when you have one: `BACKUP_REPO=sftp:user@server:/path lab backup run` (restic also handles S3,
Backblaze B2, a mounted USB disk…). A USB disk mounted on `/mnt/usb`: `BACKUP_REPO=/mnt/usb/restic` (`init` first with
the same variable). Not tested here.

### Copy to the Windows PC (script run and restore tested on the reference installation)

The PC pulls the (already encrypted) restic repository from the AI machine:
`windows\outils\Sauvegarder-AiBeast-hors-machine.bat` (double-click, VPN connected, SSH key loaded). Default
destination: `aibeast-backup\restic-repo`, next to the `windows\` folder (`-Destination` parameter to choose another
one). The location of the repository is asked from the AI machine (`lab backup repo`).
The script:
1. reads on the AI machine the number of files and the total size of the repository;
2. copies with `scp` into `restic-repo.nouveau` (*new*);
3. compares: if the numbers differ (was the 03:30 backup running?), it **replaces nothing**;
4. otherwise keeps the old copy as `restic-repo.precedent` (*previous*) and installs the new one; writes
   `derniere-copie.txt` (*last copy*).

These folder and file names keep their original spelling so that existing copies keep working.

**Where to keep the `password` file.** On the reference installation, the owner chose to keep it in `aibeast-backup`,
next to the copy, because the PC is a secured workstation. Consequence to know: on that PC, anyone who can access the
folder can read the whole repository (passwords, `N8N_ENCRYPTION_KEY`, Langfuse keys), and the copy no longer protects
against theft of or access to the workstation. On the other hand, restoring from the PC depends on nothing else. The
safer choice: keep the password in a password manager and not in the folder.

To restore from the PC: copy `restic-repo` back to the AI machine, then
`BACKUP_REPO=/path/restic-repo BACKUP_PASSWORD_FILE=... scripts/backup.sh list` (same procedure as §4).
**Tested: restore from the PC copy.** The PC's `restic-repo` copy and its `password` file were sent back to the AI
machine (into `~/restore-test`, `scp`), then `restic restore latest --include` extracted the two dumps: `n8n.sql`
(568,042 bytes, 157 `CREATE TABLE`) and `langfuse.sql` (314,814 bytes, header `PostgreSQL database cluster dump`). The PC
copy is therefore readable with its own password.
Also verified: `restic snapshots` on the copy lists **the same 5 snapshots** as the AI machine;
`restic check --read-data-subset=10%`: "no errors were found" (9 packs out of 9 read, i.e. only a tenth of the data).
Not verified: a full read of the copy (`restic check --read-data`), reloading both dumps into a database (done only for
Langfuse, from the original repository, see §4), and the full restore of the volumes (Open WebUI, n8n, Qdrant).

**Size: 1.156 GiB one day, 3.539 GiB the next on the reference machine.** Probable cause (seen with `restic ls`, not
measured in total): Hermes installed tools under `hermes/data/installs/…/workspace/tools/` (Chromium ≈ 270 MB, Python,
Node, ffmpeg…), which are backed up with the rest. These are presumably binaries Hermes can download again (not
verified: confirm before excluding anything). The largest stable file is `ai-stack_open_webui_data.tar` (1.12 GB,
identical from one day to the next, hence deduplicated by restic).
Pending decision: exclude these tools from the backup (expected gain ≈ 2.4 GiB, the observed difference, on `/data` and
on the PC), or keep them.
To run by hand (or to schedule in the Windows Task Scheduler); the copy is not automatic.

## 4. Restoring

Restoring **never** replaces the data in place: it puts it into a folder, and it is up to you to put back what is
needed.

```bash
lab backup list                                  # find the ID
scripts/backup.sh restore <ID> ~/restore         # empty folder
ls ~/restore/data/backups/staging ~/restore/home/...   # n8n.sql, *.tar
```

**n8n database** (n8n stopped during the operation):
```bash
docker stop n8n
docker exec -i postgres-n8n psql -U n8n -d n8n < ~/restore/data/backups/staging/n8n.sql
docker start n8n
```
**Volume** (Open WebUI example):
```bash
docker stop open-webui
docker run --rm -v ai-stack_open_webui_data:/dst -v ~/restore/data/backups/staging:/in alpine \
  sh -c 'rm -rf /dst/* /dst/.[!.]* 2>/dev/null; tar -C /dst -xf /in/ai-stack_open_webui_data.tar'
docker start open-webui
```
**`.env` files**: copy them from `~/restore/home/.../ai-lab/` to their original location.
**Langfuse**: `docker exec -i <postgres container> psql -U postgres < langfuse.sql` on a fresh database.
Risk-free test (done on the reference machine): load `langfuse.sql` into a throwaway PostgreSQL with the same image,
then count the rows.
```bash
IMG=$(docker inspect app-postgres-1 --format '{{.Config.Image}}')
docker run -d --rm --name pg-restore-test -e POSTGRES_PASSWORD=test "$IMG"; sleep 10
docker exec -i pg-restore-test psql -U postgres -q < ~/restore-test/.../langfuse.sql > /dev/null 2> ~/restore-test.err; echo "code: $?"
docker exec pg-restore-test psql -U postgres -d postgres -c 'select count(*) from users;' -c 'select count(*) from projects;' -c 'select count(*) from api_keys;'
docker rm -f pg-restore-test
```
"already exists" errors (roles already present in the fresh database) are harmless.

Test a restore **now**, into a test folder, before you need it: a backup that was never restored is not proven.

## 5. Safety backups of deliveries (`avant-*.tgz`)

`Deployer-sur-AiBeast` writes `~/avant-YYYYMMDD-HHMM.tgz` (*avant* = before) before each extraction (≈ 1 MB:
`bench/.venv` and `bench/results` are excluded). Since the project is a git repository, the real rollback of the code is
`git checkout`. Move them from time to time out of your home folder, for example:
`mkdir -p /data/backups/avant-deploiement && mv -n ~/avant-*.tgz /data/backups/avant-deploiement/`. That folder is not
included in restic.

## 6. What is not verified

- Verified on the reference machine: backup, list, integrity check, n8n restore, daily schedule (03:30) and restore of
  the Langfuse database into a throwaway PostgreSQL (code 0; 1 user, 2 projects, 2 API keys).
- **Not verified**: actually putting a restored database back into service (n8n or Langfuse); restoring the Open
  WebUI/Qdrant volumes.
- The exact paths in the snapshot (`data/backups/staging`, `home/...`) depend on restic; list them with
  `restic ls <ID>` if needed (`export RESTIC_REPOSITORY=… RESTIC_PASSWORD_FILE=…`).
- The Langfuse container is found through the folder of its compose file (`langfuse/app`, service `postgres`), not
  through the project name (Docker names it `app`).
- **What is backed up for Langfuse**: the PostgreSQL database (accounts, projects, API keys, prompts) and its `.env`.
  **Not** ClickHouse (the traces themselves) nor MinIO: agent traces can be rebuilt, keys and settings cannot.
- The volume names (`ai-stack_*`) assume the project name `ai-stack` (it is set in the compose file).
