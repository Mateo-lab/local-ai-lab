#!/usr/bin/env bash
# Donne à Hermes l'accès SSH à UNE machine de test, avec une clé dédiée et une empreinte vérifiée.
# Appelé par `lab remote …` (voir docs/hermes-ssh.md).
#
#   remote.sh add NOM UTILISATEUR@HOTE [PORT] [--windows] [--yes]   clé dédiée + empreinte épinglée + entrée de config ; affiche quoi faire sur la machine
#   remote.sh show NOM [--windows]                      réaffiche ce qu'il faut faire sur la machine (clé incluse)
#   remote.sh list                                      machines connues de Hermes
#   remote.sh link NOM PROJET                           ajoute à l'AGENTS.md d'un projet existant les règles d'usage de cette machine
#   remote.sh test NOM                                  essaie la connexion DEPUIS le conteneur Hermes (celle de l'agent)
#   remote.sh remove NOM                                supprime clé, empreinte et entrée
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HDIR="$ROOT/hermes"
DATA="${HERMES_DATA:-$HDIR/data}"
SSHD="$DATA/ssh"             # vu comme /opt/data/ssh dans le conteneur
INSIDE=/opt/data/ssh
die() { echo "lab remote : $*" >&2; exit 1; }

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "nom invalide « $1 » (minuscules, chiffres et -, 31 caractères max)"; }
# Ces valeurs finissent dans un fichier de configuration ssh : on n'accepte que des caractères inoffensifs
# (sinon une valeur piégée pourrait ajouter une option ProxyCommand).
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "utilisateur invalide « $1 »"; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || die "hôte invalide « $1 » (nom DNS ou adresse IPv4)"; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "port invalide « $1 »"; }
exists() { [ -f "$SSHD/config" ] && grep -qx "Host $1" "$SSHD/config"; }

# Affiche ce qu'il faut faire sur la machine (clé publique incluse). Utilisé par add et show.
print_instructions() {
  local name="$1" user="$2" host="$3" win="$4" key="$SSHD/id_ed25519_$1"
  local src=""; command -v ip >/dev/null && src="$(ip -4 route get "$host" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)"
  local from=""; [ -n "$src" ] && from=",from=\"$src\""
  echo
  local line="restrict,pty$from $(cat "$key.pub")"
  if [ -n "$win" ]; then
    echo "Clé créée. À faire SUR le PC Windows « $name », dans PowerShell lancé en tant qu'administrateur :"
    echo
    local t; t="$(cat <<'PS'
# 1. Serveur SSH (ignore l'erreur s'il est déjà installé)
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic; Start-Service sshd
# 2. Utilisateur dédié : simple utilisateur (PAS administrateur), mot de passe aléatoire que personne ne connaît
$g = (New-Guid).ToString('N')
$pw = ConvertTo-SecureString ($g + 'aA1!') -AsPlainText -Force
New-LocalUser -Name '@USER@' -Password $pw -PasswordNeverExpires -Description 'Acces SSH Hermes'
Get-LocalGroup -SID S-1-5-32-545 | Add-LocalGroupMember -Member '@USER@'   # groupe « Utilisateurs », quelle que soit la langue de Windows
# 3. Clé autorisée, rangée hors du profil
$f = 'C:\ProgramData\ssh\@USER@_authorized_keys'
Set-Content -Path $f -Value '@LINE@' -Encoding ascii
Test-Path $f   # doit afficher True
# SYSTEM, Administrateurs : identifiants universels (SID), valables en français comme en anglais
icacls $f /inheritance:r
icacls $f /grant '*S-1-5-18:F'
icacls $f /grant '*S-1-5-32-544:F'
icacls $f /grant '@USER@:R'
icacls $f   # doit lister seulement SYSTEM, Administrateurs et @USER@
# 4. Pour cet utilisateur seulement : clé uniquement, pas de mot de passe
# (et aucun tunnel : ni redirection de port, ni SOCKS, ni agent, ni X11)
Add-Content 'C:\ProgramData\ssh\sshd_config' "`nMatch User @USER@`n    AuthorizedKeysFile C:/ProgramData/ssh/@USER@_authorized_keys`n    PasswordAuthentication no`n    AllowTcpForwarding no`n    AllowStreamLocalForwarding no`n    PermitTunnel no`n    AllowAgentForwarding no`n    X11Forwarding no`n    GatewayPorts no"
Restart-Service sshd
# 5. Couper Internet sur cette machine (sinon l'agent pourrait y lancer des commandes qui sortent) :
#    windows\outils\Isoler-machine-de-test.ps1, en administrateur (docs/isolation-agents.md)
PS
)"
    t="${t//@USER@/$user}"; t="${t//@LINE@/$line}"
    echo "$t" | sed 's/^/  /'
    echo
    echo "Pour comparer l'empreinte (à taper sur le PC) :  ssh-keygen -lf C:\\ProgramData\\ssh\\ssh_host_ed25519_key.pub"
    echo "Le shell distant de Windows est cmd.exe. Les outils installés dans TON profil (PlatformIO, Python, Arduino…) ne sont pas visibles pour « $user » : installe-les pour tous les utilisateurs, ou dans son profil."
  else
    echo "Clé créée. À faire SUR la machine « $name » (en tant qu'administrateur) :"
    echo
    echo "  sudo adduser --disabled-password --gecos '' $user"
    echo "  sudo install -d -m 700 -o $user -g $user /home/$user/.ssh"
    echo "  echo '$line' | sudo tee /home/$user/.ssh/authorized_keys"
    echo "  sudo chown $user:$user /home/$user/.ssh/authorized_keys && sudo chmod 600 /home/$user/.ssh/authorized_keys"
  fi
  echo
  echo "Puis : lab remote test $name"
  [ -n "$src" ] || echo "(adresse source non déterminée : la restriction from=\"…\" n'a pas été ajoutée, tu peux la rajouter à la main)"
}

cmd_add() {
  local yes="" win=""; local args=(); for a in "$@"; do case "$a" in --yes) yes=1;; --windows) win=1;; *) args+=("$a");; esac; done
  local name="${args[0]:-}" target="${args[1]:-}" port="${args[2]:-22}"
  [ -n "$name" ] && [ -n "$target" ] || die "usage : lab remote add NOM UTILISATEUR@HOTE [PORT]"
  [[ "$target" == *@* ]] || die "attendu : UTILISATEUR@HOTE"
  local user="${target%@*}" host="${target#*@}"
  valid_name "$name"; valid_user "$user"; valid_host "$host"; valid_port "$port"
  command -v ssh-keygen >/dev/null || die "il manque ssh-keygen"
  exists "$name" && die "« $name » existe déjà (lab remote remove $name pour la refaire)"
  mkdir -p "$SSHD" && chmod 700 "$SSHD"; touch "$SSHD/config" "$SSHD/known_hosts"; chmod 600 "$SSHD/config" "$SSHD/known_hosts"

  # 1. Empreinte de la machine, à vérifier AVANT de lui faire confiance.
  local hk tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  if [ -n "${REMOTE_HOSTKEY_FILE:-}" ]; then cp "$REMOTE_HOSTKEY_FILE" "$tmp"
  else command -v ssh-keyscan >/dev/null || die "il manque ssh-keyscan"
       ssh-keyscan -T 8 -t ed25519 -p "$port" "$host" 2>/dev/null | grep -v '^#' > "$tmp"; fi
  hk="$(head -n1 "$tmp")"
  [[ "$hk" =~ ^[^[:space:]]+[[:space:]]ssh-ed25519[[:space:]][A-Za-z0-9+/=]+$ ]] || die "pas de clé ed25519 reçue de $host:$port (machine éteinte, port fermé, ou pas de clé ed25519)"
  local pub="${hk#* }"
  echo "Empreinte présentée par $host:$port :"
  echo "  $(echo "$pub" | ssh-keygen -lf - 2>/dev/null)"
  echo "Compare-la avec celle de la machine (à taper SUR la machine) :"
  echo "  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
  if [ -z "$yes" ]; then read -r -p "Ce sont les mêmes ? [o/N] " r; [[ "$r" =~ ^[oOyY]$ ]] || die "abandon : empreinte non confirmée"; fi

  # 2. Clé dédiée à cette machine, sans phrase secrète (l'agent doit pouvoir s'en servir seul).
  local key="$SSHD/id_ed25519_$name"
  ssh-keygen -q -t ed25519 -N "" -C "hermes@aibeast-$name" -f "$key" || die "ssh-keygen a échoué"
  chmod 600 "$key"
  # Épingle l'empreinte : « [hôte]:port » si le port n'est pas 22, comme ssh l'attend.
  if [ "$port" = 22 ]; then echo "$host $pub" >> "$SSHD/known_hosts"; else echo "[$host]:$port $pub" >> "$SSHD/known_hosts"; fi
  {
    echo "Host $name"
    echo "  HostName $host"; echo "  User $user"; echo "  Port $port"
    echo "  IdentityFile $INSIDE/id_ed25519_$name"; echo "  IdentitiesOnly yes"
    echo "  UserKnownHostsFile $INSIDE/known_hosts"; echo "  StrictHostKeyChecking yes"
    echo "  BatchMode yes"; echo "  ConnectTimeout 10"; echo "  ServerAliveInterval 15"
    echo "  ForwardAgent no"; echo "  ForwardX11 no"
    echo
  } >> "$SSHD/config"

  print_instructions "$name" "$user" "$host" "$win"
}

cmd_show() {
  local name="" win=""; for a in "$@"; do case "$a" in --windows) win=1;; *) name="$a";; esac; done
  [ -n "$name" ] || die "usage : lab remote show NOM [--windows]"; valid_name "$name"; exists "$name" || die "« $name » inconnue (lab remote list)"
  [ -f "$SSHD/id_ed25519_$name.pub" ] || die "clé de « $name » introuvable"
  local user host
  user="$(awk -v n="$name" '$1=="Host"{c=($2==n)} c&&$1=="User"{print $2}' "$SSHD/config")"
  host="$(awk -v n="$name" '$1=="Host"{c=($2==n)} c&&$1=="HostName"{print $2}' "$SSHD/config")"
  valid_user "$user"; valid_host "$host"
  print_instructions "$name" "$user" "$host" "$win"
}

cmd_list() {
  [ -f "$SSHD/config" ] || { echo "Aucune machine."; return 0; }
  awk '$1=="Host"{n=$2} $1=="HostName"{h=$2} $1=="User"{u=$2} $1=="Port"{p=$2} /^$/ && n{print n"\t"u"@"h":"p; n=""}' "$SSHD/config"
}

cmd_test() {
  local name="${1:?usage : lab remote test NOM}"; valid_name "$name"; exists "$name" || die "« $name » inconnue (lab remote list)"
  command -v docker >/dev/null || die "il manque docker"
  [ -f "$HDIR/.env" ] || printf 'HERMES_UID=%s\nHERMES_GID=%s\n' "$(id -u)" "$(id -g)" > "$HDIR/.env"
  echo "Connexion depuis le conteneur Hermes (c'est ce que verra l'agent)…"
  # Test Internet/DNS lancé SUR la machine (Windows) ; encodé pour éviter tout problème de guillemets
  local enc; enc="$(printf '%s' '$c=New-Object Net.Sockets.TcpClient;try{$o=$c.ConnectAsync("1.1.1.1",443).Wait(4000)}catch{$o=$false};$c.Close();try{$d=[Net.Dns]::GetHostAddressesAsync("example.com").Wait(5000)}catch{$d=$false};"internet="+$o+" dns="+$d' | iconv -t UTF-16LE | base64 -w0)"
  local probe="command -v ssh >/dev/null || { echo 'ERREUR : pas de client ssh dans l image Hermes'; exit 3; }
S='ssh -n -F $INSIDE/config $name'
echo -n 'utilisateur : '; \$S whoami || exit 4
echo -n 'machine     : '; \$S hostname
if \$S 'whoami /groups' 2>/dev/null | grep -q 'S-1-5-32-544'; then echo 'ATTENTION : cet utilisateur est membre des administrateurs Windows'; fi
if \$S 'sudo -n true' >/dev/null 2>&1; then echo 'ATTENTION : sudo possible sans mot de passe'; else echo 'pas de sudo sans mot de passe : bien'; fi
if timeout 15 ssh -F $INSIDE/config -W 127.0.0.1:22 $name < /dev/null 2>&1 | grep -q 'SSH-2.0'; then echo 'ATTENTION : tunnel SSH possible (redirection de port) : voir docs/isolation-agents.md'; else echo 'tunnel SSH refusé : bien'; fi
if \$S ver 2>/dev/null | grep -qi windows; then
  r=\$(\$S powershell -NoProfile -NonInteractive -EncodedCommand $enc 2>/dev/null | tr -d '\\r')
  case \"\$r\" in *internet=False*) echo 'Internet depuis la machine : bloqué, bien';; *) echo \"ATTENTION : la machine a accès à Internet (\$r) : windows/outils/Isoler-machine-de-test.ps1\";; esac
  case \"\$r\" in *dns=False*) echo 'DNS depuis la machine : bloqué, bien';; *dns=True*) echo 'DNS depuis la machine : résolu (canal de sortie possible ; sauf -GarderDns voulu)';; esac
fi"
  # ssh refuse de tourner si l'identifiant numérique n'a pas d'entrée dans /etc/passwd (« No user exists for uid 1000 »).
  # Ici on contourne le démarrage normal de l'image, qui crée cet utilisateur : on ajoute donc l'entrée dans une copie de /etc/passwd.
  local pw; pw="$(mktemp)"; trap 'rm -f "$pw"' RETURN
  ( cd "$HDIR" && docker compose run --rm -T --entrypoint cat hermes /etc/passwd > "$pw" 2>/dev/null ) || true
  grep -q "^[^:]*:[^:]*:$(id -u):" "$pw" || echo "hermes-host:x:$(id -u):$(id -g):hermes:/opt/data:/bin/bash" >> "$pw"
  chmod 644 "$pw"
  ( cd "$HDIR" && timeout 120 docker compose run --rm -T --user "$(id -u):$(id -g)" -v "$pw:/etc/passwd:ro" --entrypoint bash hermes -lc "$probe" < /dev/null )   # < /dev/null et ssh -n : rien ne doit attendre le clavier
  local rc=$?
  [ $rc -eq 0 ] && echo "OK. L'agent s'y connecte avec : ssh -F $INSIDE/config $name '…'" || echo "Échec (code $rc). Causes fréquentes : clé pas encore installée sur la machine, pare-feu, empreinte changée."
  return $rc
}

cmd_link() {
  local name="${1:?usage : lab remote link NOM PROJET}" proj="${2:?usage : lab remote link NOM PROJET}"
  valid_name "$name"; [[ "$proj" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || die "projet invalide « $proj »"
  exists "$name" || die "« $name » inconnue (lab remote add d'abord)"
  local P="$DATA/workspace/projects/$proj" F="$DATA/workspace/projects/$proj/AGENTS.md"
  # L'agent écrit dans ce dossier : on refuse les liens symboliques, qui feraient écrire ailleurs sur AiBeast.
  [ -d "$P" ] && [ ! -L "$P" ] || die "projet « $proj » introuvable (ou lien symbolique) dans $DATA/workspace/projects"
  [ ! -L "$F" ] || die "$F est un lien symbolique : refus par sécurité"
  local tpl="$HDIR/dev-template/AGENTS.md"
  [ -f "$tpl" ] || die "modèle introuvable : $tpl"
  if [ -f "$F" ] && grep -q "^Machine de test autorisée : \`$name\`" "$F"; then echo "Déjà fait pour $proj."; return 0; fi
  {
    echo
    sed -n '/^## Machines de test (SSH)/,$p' "$tpl" | sed "1a Machine de test autorisée : \`$name\`"
  } >> "$F"
  echo "Règles ajoutées à $F. Dis à Hermes (dans sa session) :"
  echo "  « Relis AGENTS.md. Tu peux te connecter à la machine $name avec ssh -F /opt/data/ssh/config $name 'commande'. »"
}

cmd_remove() {
  local name="${1:?usage : lab remote remove NOM}"; valid_name "$name"; exists "$name" || die "« $name » inconnue"
  local host port; host="$(awk -v n="$name" '$1=="Host"{c=($2==n)} c&&$1=="HostName"{print $2}' "$SSHD/config")"
  port="$(awk -v n="$name" '$1=="Host"{c=($2==n)} c&&$1=="Port"{print $2}' "$SSHD/config")"
  awk -v n="$name" '$1=="Host"{skip=($2==n)} !skip' "$SSHD/config" > "$SSHD/config.new" && mv "$SSHD/config.new" "$SSHD/config"; chmod 600 "$SSHD/config"
  local pat="$host"; [ "$port" != 22 ] && pat="[$host]:$port"
  grep -vF -- "$pat " "$SSHD/known_hosts" > "$SSHD/known_hosts.new"; mv "$SSHD/known_hosts.new" "$SSHD/known_hosts"; chmod 600 "$SSHD/known_hosts"
  rm -f "$SSHD/id_ed25519_$name" "$SSHD/id_ed25519_$name.pub"
  echo "Supprimé côté AiBeast. Pense à retirer la ligne « hermes@aibeast-$name » de ~/.ssh/authorized_keys sur la machine, ou à supprimer son utilisateur."
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;; show) shift; cmd_show "$@" ;; list) cmd_list ;; link) shift; cmd_link "$@" ;; test) shift; cmd_test "$@" ;; remove) shift; cmd_remove "$@" ;;
  *) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
