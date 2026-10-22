# Hermes : accès SSH à une machine de test

Pour que Hermes déploie et exécute du code sur une machine de test (VM ou PC à toi), sans lui donner tes propres clés ni un accès large.

## Principe

- **Une clé par machine**, créée pour Hermes (`hermes@aibeast-NOM`), valable seulement sur cette machine.
- **Un utilisateur dédié** sur la machine, sans `sudo`, qui ne voit que son dossier. Le pire cas est donc limité à cet utilisateur et à ce qu'il atteint par le réseau.
- **Empreinte de la machine épinglée** (`StrictHostKeyChecking yes`) : on la vérifie une fois, à la création.
- **Clé restreinte côté machine** : `restrict,pty,from="adresse d'AiBeast"` : pas de redirection de ports, pas d'agent SSH, connexion acceptée seulement depuis AiBeast.
- L'agent ne reçoit que la commande `ssh -F /opt/data/ssh/config NOM …` (règle écrite dans `AGENTS.md` des nouveaux projets).

## Mise en place

Sur AiBeast :

```
lab remote add NOM hermes@ADRESSE_DE_LA_MACHINE   # ajoute --windows pour un PC Windows
```

1. La commande affiche l'empreinte présentée par la machine. Sur la machine, tape `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` et compare. Réponds `o` si elles sont identiques.
2. Elle crée la clé dans `hermes/data/ssh/` et affiche **4 commandes à taper sur la machine** (création de l'utilisateur et de `authorized_keys`).
3. `lab remote test NOM` essaie la connexion **depuis le conteneur Hermes** et signale si l'utilisateur a un `sudo` (il ne devrait pas).

4. Pour un projet **déjà existant** (par exemple `mon_projet`) : `lab remote link NOM mon_projet` ajoute à son `AGENTS.md` les règles d'usage de la machine (sans toucher au reste du fichier) et affiche la phrase à dire à Hermes.

`lab remote show NOM [--windows]` réaffiche ce qu'il faut faire sur la machine, avec ta clé déjà dedans (utile si tu as perdu l'affichage ou si une étape a échoué).

Autres commandes : `lab remote list`, `lab remote remove NOM`.

Les nouveaux projets reçoivent ces règles à la création ; pour les anciens, c'est `lab remote link`.

## Si la machine est un PC Windows

Ajoute `--windows` : `lab remote add NOM hermes@ADRESSE --windows`. Au lieu des commandes Linux, la commande affiche un bloc **PowerShell à lancer en administrateur sur le PC** : installation du serveur OpenSSH, création d'un utilisateur `hermes` qui est un simple utilisateur (pas administrateur, mot de passe aléatoire inconnu), clé rangée hors de son profil, connexion par clé seulement pour ce compte. Empreinte à comparer : `ssh-keygen -lf C:\ProgramData\ssh\ssh_host_ed25519_key.pub`.

À savoir sous Windows :
- Le shell distant est `cmd.exe` ; Hermes lance `powershell -NoProfile -Command "…"` pour le reste (c'est écrit dans ses règles).
- Les outils installés dans **ton** profil (Python, PlatformIO, Arduino…) sont invisibles pour `hermes` : installe-les pour tous les utilisateurs.
- Si le PC est **ton PC principal**, l'utilisateur dédié ne voit pas ton profil, mais il voit les dossiers partagés (`C:\Users\Public`, disques sans restriction). Mets les fichiers de travail dans son dossier `work\<projet>` et vérifie ce qu'il peut lire avant de lui confier quoi que ce soit.
- Le pare-feu Windows peut limiter l'accès SSH à l'adresse d'AiBeast : `Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -RemoteAddress ADRESSE_AIBEAST`.
- Il faut qu'AiBeast **atteigne** le PC (même réseau, ou VPN dans les deux sens) : `ping -c 2 ADRESSE` depuis AiBeast.

## Bonnes pratiques

- **Isolation** : Hermes n'a aucun accès réseau sauf ceux que tu autorises. Ajoute l'adresse de la machine à
  `LAB_AGENT_SSH_ALLOW` dans `lab.conf`, puis `lab isolation apply` : sinon la connexion SSH est bloquée
  ([isolation-agents.md](isolation-agents.md)).
- **Pas d'Internet par la machine de test** : lance `windows\outils\Isoler-machine-de-test.ps1` en administrateur sur
  la machine (Internet et DNS coupés pour toute la machine, tunnels SSH interdits au compte de Hermes), puis
  `lab remote test NOM` (section 5 d'[isolation-agents.md](isolation-agents.md)).

- **Prends un instantané de la VM** avant chaque séance : l'agent peut casser la machine, par erreur ou parce qu'un texte lu l'y a poussé.
- **Utilise une machine sans secret** : pas de jetons, pas de clés d'autres machines, pas de partage réseau monté, et si possible isolée de ton réseau sensible. Hermes, lui, ne peut atteindre que ce que la machine atteint.
- Si les tests ont besoin d'installer des paquets, installe-les toi-même avant ; ne donne pas `sudo` à l'utilisateur. Si c'est indispensable, une règle `sudoers` limitée à une commande précise vaut mieux qu'un `sudo` complet.
- Ces accès sont **à la demande** : Hermes ne tourne que quand tu le lances. Si tu n'en as plus besoin, `lab remote remove NOM` puis retire la clé sur la machine.

## Limites

- **Hermes lit la clé** : elle est dans son dossier de données, il doit pouvoir s'en servir. Si un texte malveillant le manipule, il peut l'utiliser sur cette machine, d'où l'utilisateur sans droits. Il ne la sortira de l'ordinateur que s'il a aussi un accès à Internet : le conteneur n'est pas coupé du réseau.
- Rien n'empêche techniquement l'agent de joindre d'autres machines de ton réseau local, mais sa clé n'y marche pas. Pour l'en empêcher aussi, il faudrait une règle de pare-feu sur AiBeast (chaîne `DOCKER-USER`) : possible, non fournie.
- Les règles d'`AGENTS.md` guident l'agent, elles ne l'obligent pas.

## Retour d'expérience : de la création au premier test réussi

Mise en place réelle sur un PC Windows de test (`pc-test`, projet `mon_projet`, Hermes doit y envoyer des commandes I²C). Résultat final : `lab remote test pc-test` réussit, avec un utilisateur `hermes` sans administrateur ni `sudo`. Voici dans l'ordre ce qui a posé problème, et la solution.

### Sur AiBeast

| Symptôme | Cause | Solution |
|---|---|---|
| `lab remote test` : « No user exists for uid 1000 » | `ssh` refuse de tourner si l'identifiant du conteneur n'a pas d'entrée dans `/etc/passwd` (conteneur lancé avec `--entrypoint bash`) | Le test monte une copie de `/etc/passwd` où cette entrée est ajoutée |
| `lab remote test` reste bloqué après la dernière ligne | `ssh` attend l'entrée standard | `ssh -n` et `< /dev/null` dans le test |
| `lab remote add` refuse : « existe déjà » | Une machine du même nom est déjà enregistrée | `lab remote remove NOM`, puis `add`. **Attention : une nouvelle clé est alors générée.** La clé affichée par `lab remote show NOM --windows` change donc après un `remove`/`add`, et celle déjà collée sur le PC ne marche plus : recolle le bloc affiché par `show` |

### Sur le PC Windows

| Symptôme | Cause | Solution |
|---|---|---|
| `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` : fichier introuvable | Chemin Linux | `ssh-keygen -lf C:\ProgramData\ssh\ssh_host_ed25519_key.pub` |
| « unexpected newguid » | `[guid]::NewGuid()` mal collé dans le terminal | `(New-Guid).ToString('N')` |
| `icacls` : « invalid parameter /inheritancer » | Faute de frappe (`:` manquant) | `/inheritance:r` |
| « the system cannot find the specified file » | Nom d'utilisateur : l'aide affichait `hermes-test` alors que le compte créé s'appelle `hermes` | Utiliser le même nom partout : `hermes` |
| « Access denied » en modifiant le fichier de clés | PowerShell non lancé en administrateur, ou fichier appartenant à un autre compte | Lancer PowerShell **en administrateur** ; au besoin `takeown /f $f` |
| `Permission denied (publickey,password,keyboard-interactive)` côté AiBeast, alors que tout semblait correct | Voir ci-dessous | Voir ci-dessous |

**Cause finale du refus de clé.** Le journal du PC (`Get-WinEvent -LogName OpenSSH/Operational -MaxEvents 20`) indiquait :

```
Authentication refused: bad ownership or modes for file C:\ProgramData\ssh\hermes_authorized_keys
Bad permissions … Administrator
```

Avec `StrictModes yes` (par défaut), `sshd` refuse un fichier de clés dont la liste de droits contient un compte autre que : `SYSTEM`, le groupe Administrateurs et l'utilisateur concerné. Une entrée **`Administrator`** (le compte, pas le groupe) y figurait. Le journal est le seul endroit où cette cause apparaît : côté AiBeast on ne voit que « Permission denied ».

Correction :

```
icacls $f /remove 'Administrator'
icacls $f /grant 'hermes:R'
icacls $f
```

`icacls $f` ne doit lister que `SYSTEM`, `Administrators` et `hermes`. Ensuite `Restart-Service sshd`.

**Pistes qui ne sont pas la cause** (pour ne pas y repasser du temps) :
- La ligne `AuthorizedKeysFile C:/ProgramData/ssh/administrators_authorized_keys` vue dans `sshd -T` vient du bloc `Match Group administrators` de Windows. Elle ne concerne pas un utilisateur qui n'est pas administrateur.
- `sshd -T` seul affiche « ga_init, unable to resolve user hermes » : la commande doit recevoir l'utilisateur, par exemple `sshd -T -C user=hermes,host=x,addr=x`.
- Le niveau de log `DEBUG3` dans `sshd_config` a servi au diagnostic et n'est pas à laisser en service.

### Commandes de diagnostic à garder

Sur AiBeast :

```
lab remote test NOM
ssh -v -F hermes/data/ssh/config NOM       # trace détaillée côté client
```

Sur le PC (PowerShell administrateur) :

```
Get-WinEvent -LogName OpenSSH/Operational -MaxEvents 20 | Format-List TimeCreated,Message
icacls C:\ProgramData\ssh\hermes_authorized_keys
Get-Service sshd
```

### Après un redémarrage du PC

Le service est réglé en démarrage automatique (`Set-Service sshd -StartupType Automatic`) : la connexion revient toute seule. Seule condition : **le PC garde la même adresse IP**. Si elle change, `lab remote remove` puis `add` avec la nouvelle adresse, ou réserve l'adresse dans le routeur.

### Remise en état après le diagnostic

Si le niveau de log a été monté pour chercher la panne, remets la configuration d'origine :

```
Copy-Item C:\ProgramData\ssh\sshd_config.bak C:\ProgramData\ssh\sshd_config -Force
Restart-Service sshd
```

(à faire avec la sauvegarde que tu as prise ; vérifie ensuite que la ligne `Match User hermes` y est toujours, sinon `lab remote show NOM --windows` la redonne).

## Ce qui reste à vérifier

- **Session Hermes réelle.** Le test passe depuis un conteneur lancé exprès. Dans une vraie session, demande à Hermes d'exécuter `ssh -F /opt/data/ssh/config NOM whoami` et attends `hermes`. Si `ssh` manque dans l'image, `lab remote test` le signale.
- **`lab remote link NOM PROJET`** (ajoute les règles à l'`AGENTS.md` du projet) n'a pas été confirmé sur `mon_projet`.
- **Pas de garde-fou sur les commandes I²C.** Hermes peut envoyer ce qu'il veut au bus avec les droits de `hermes`. Un script d'enveloppe limitant les adresses et les commandes serait une étape suivante.
- **Adresse source `from="…"`** : déduite de la route d'AiBeast vers la machine. Avec un VPN ou du NAT, le PC peut voir une autre adresse ; retire alors `from=` ou corrige-le.
- **Règle de pare-feu** limitant l'accès SSH à l'adresse d'AiBeast : non faite.
- `lab remote link` refuse un projet ou un `AGENTS.md` qui serait un lien symbolique (testé).
- Les tests automatiques (`scripts/test-remote.sh`) utilisent une **simulation de `ssh-keygen`** : ils vérifient la validation des noms (contre l'injection dans la config ssh), les droits de fichiers, l'épinglage et la suppression. La vraie connexion a été validée à la main, comme décrit plus haut.
