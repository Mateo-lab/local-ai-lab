#!/usr/bin/env bash
# Gives Hermes SSH access to ONE test machine, with a dedicated key and a verified fingerprint.
# Called by `lab remote …` (see docs/hermes-ssh.md).
#
#   remote.sh add NAME USER@HOST [PORT] [--windows] [--yes]   dedicated key + pinned fingerprint + config entry; shows what to do on the machine
#   remote.sh show NAME [--windows]                     shows again what to do on the machine (key included)
#   remote.sh list                                      machines known to Hermes
#   remote.sh link NAME PROJECT                         adds the rules for using this machine to an existing project's AGENTS.md
#   remote.sh test NAME                                 tries the connection FROM the Hermes container (the agent's)
#   remote.sh remove NAME                               removes key, fingerprint and entry
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HDIR="$ROOT/hermes"
DATA="${HERMES_DATA:-$HDIR/data}"
SSHD="$DATA/ssh"             # seen as /opt/data/ssh in the container
INSIDE=/opt/data/ssh
die() { echo "lab remote: $*" >&2; exit 1; }

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "invalid name \"$1\" (lower case, digits and -, 31 characters max)"; }
# These values end up in an ssh configuration file: only harmless characters are accepted
# (otherwise a trapped value could add a ProxyCommand option).
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user \"$1\""; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || die "invalid host \"$1\" (DNS name or IPv4 address)"; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || die "invalid port \"$1\""; }
exists() { [ -f "$SSHD/config" ] && grep -qx "Host $1" "$SSHD/config"; }

# Shows what to do on the machine (public key included). Used by add and show.
print_instructions() {
  local name="$1" user="$2" host="$3" win="$4" key="$SSHD/id_ed25519_$1"
  local src=""; command -v ip >/dev/null && src="$(ip -4 route get "$host" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)"
  local from=""; [ -n "$src" ] && from=",from=\"$src\""
  echo
  local line="restrict,pty$from $(cat "$key.pub")"
  if [ -n "$win" ]; then
    echo "Key created. To do ON the Windows PC \"$name\", in PowerShell run as administrator:"
    echo
    local t; t="$(cat <<'PS'
# 1. SSH server (ignore the error if it is already installed)
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic; Start-Service sshd
# 2. Dedicated user: plain user (NOT an administrator), random password nobody knows
$g = (New-Guid).ToString('N')
$pw = ConvertTo-SecureString ($g + 'aA1!') -AsPlainText -Force
New-LocalUser -Name '@USER@' -Password $pw -PasswordNeverExpires -Description 'Acces SSH Hermes'
Get-LocalGroup -SID S-1-5-32-545 | Add-LocalGroupMember -Member '@USER@'   # "Users" group, whatever the language of Windows
# 3. Authorized key, stored outside the profile
$f = 'C:\ProgramData\ssh\@USER@_authorized_keys'
Set-Content -Path $f -Value '@LINE@' -Encoding ascii
Test-Path $f   # must show True
# SYSTEM, Administrators: universal identifiers (SID), valid whatever the language of Windows
icacls $f /inheritance:r
icacls $f /grant '*S-1-5-18:F'
icacls $f /grant '*S-1-5-32-544:F'
icacls $f /grant '@USER@:R'
icacls $f   # must only list SYSTEM, Administrators and @USER@
# 4. For this user only: key only, no password
# (and no tunnel: no port forwarding, no SOCKS, no agent, no X11)
Add-Content 'C:\ProgramData\ssh\sshd_config' "`nMatch User @USER@`n    AuthorizedKeysFile C:/ProgramData/ssh/@USER@_authorized_keys`n    PasswordAuthentication no`n    AllowTcpForwarding no`n    AllowStreamLocalForwarding no`n    PermitTunnel no`n    AllowAgentForwarding no`n    X11Forwarding no`n    GatewayPorts no"
Restart-Service sshd
# 5. Cut the Internet on this machine (otherwise the agent could run commands there that go out):
#    windows\outils\Isoler-machine-de-test.ps1, as administrator (docs/agent-isolation.md)
PS
)"
    t="${t//@USER@/$user}"; t="${t//@LINE@/$line}"
    echo "$t" | sed 's/^/  /'
    echo
    echo "To compare the fingerprint (type it on the PC):  ssh-keygen -lf C:\\ProgramData\\ssh\\ssh_host_ed25519_key.pub"
    echo "The remote shell on Windows is cmd.exe. Tools installed in YOUR profile (PlatformIO, Python, Arduino…) are not visible to \"$user\": install them for all users, or in its profile."
  else
    echo "Key created. To do ON the machine \"$name\" (as an administrator):"
    echo
    echo "  sudo adduser --disabled-password --gecos '' $user"
    echo "  sudo install -d -m 700 -o $user -g $user /home/$user/.ssh"
    echo "  echo '$line' | sudo tee /home/$user/.ssh/authorized_keys"
    echo "  sudo chown $user:$user /home/$user/.ssh/authorized_keys && sudo chmod 600 /home/$user/.ssh/authorized_keys"
  fi
  echo
  echo "Then: lab remote test $name"
  [ -n "$src" ] || echo "(source address not determined: the from=\"…\" restriction was not added, you can add it by hand)"
}

cmd_add() {
  local yes="" win=""; local args=(); for a in "$@"; do case "$a" in --yes) yes=1;; --windows) win=1;; *) args+=("$a");; esac; done
  local name="${args[0]:-}" target="${args[1]:-}" port="${args[2]:-22}"
  [ -n "$name" ] && [ -n "$target" ] || die "usage: lab remote add NAME USER@HOST [PORT]"
  [[ "$target" == *@* ]] || die "expected: USER@HOST"
  local user="${target%@*}" host="${target#*@}"
  valid_name "$name"; valid_user "$user"; valid_host "$host"; valid_port "$port"
  command -v ssh-keygen >/dev/null || die "ssh-keygen is missing"
  exists "$name" && die "\"$name\" already exists (lab remote remove $name to redo it)"
  mkdir -p "$SSHD" && chmod 700 "$SSHD"; touch "$SSHD/config" "$SSHD/known_hosts"; chmod 600 "$SSHD/config" "$SSHD/known_hosts"

  # 1. The machine's fingerprint, to check BEFORE trusting it.
  local hk tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  if [ -n "${REMOTE_HOSTKEY_FILE:-}" ]; then cp "$REMOTE_HOSTKEY_FILE" "$tmp"
  else command -v ssh-keyscan >/dev/null || die "ssh-keyscan is missing"
       ssh-keyscan -T 8 -t ed25519 -p "$port" "$host" 2>/dev/null | grep -v '^#' > "$tmp"; fi
  hk="$(head -n1 "$tmp")"
  [[ "$hk" =~ ^[^[:space:]]+[[:space:]]ssh-ed25519[[:space:]][A-Za-z0-9+/=]+$ ]] || die "no ed25519 key received from $host:$port (machine off, port closed, or no ed25519 key)"
  local pub="${hk#* }"
  echo "Fingerprint presented by $host:$port:"
  echo "  $(echo "$pub" | ssh-keygen -lf - 2>/dev/null)"
  echo "Compare it with the machine's (type this ON the machine):"
  echo "  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
  if [ -z "$yes" ]; then read -r -p "Are they the same? [y/N] " r; [[ "$r" =~ ^([yYoO]|yes|oui)$ ]] || die "aborted: fingerprint not confirmed"; fi

  # 2. Key dedicated to this machine, without a passphrase (the agent must be able to use it alone).
  local key="$SSHD/id_ed25519_$name"
  ssh-keygen -q -t ed25519 -N "" -C "hermes@aibeast-$name" -f "$key" || die "ssh-keygen failed"
  chmod 600 "$key"
  # Pins the fingerprint: "[host]:port" if the port is not 22, as ssh expects.
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
  [ -n "$name" ] || die "usage: lab remote show NAME [--windows]"; valid_name "$name"; exists "$name" || die "\"$name\" unknown (lab remote list)"
  [ -f "$SSHD/id_ed25519_$name.pub" ] || die "key of \"$name\" not found"
  local user host
  user="$(awk -v n="$name" '$1=="Host"{c=($2==n)} c&&$1=="User"{print $2}' "$SSHD/config")"
  host="$(awk -v n="$name" '$1=="Host"{c=($2==n)} c&&$1=="HostName"{print $2}' "$SSHD/config")"
  valid_user "$user"; valid_host "$host"
  print_instructions "$name" "$user" "$host" "$win"
}

cmd_list() {
  [ -f "$SSHD/config" ] || { echo "No machine."; return 0; }
  awk '$1=="Host"{n=$2} $1=="HostName"{h=$2} $1=="User"{u=$2} $1=="Port"{p=$2} /^$/ && n{print n"\t"u"@"h":"p; n=""}' "$SSHD/config"
}

cmd_test() {
  local name="${1:?usage: lab remote test NAME}"; valid_name "$name"; exists "$name" || die "\"$name\" unknown (lab remote list)"
  command -v docker >/dev/null || die "docker is missing"
  [ -f "$HDIR/.env" ] || printf 'HERMES_UID=%s\nHERMES_GID=%s\n' "$(id -u)" "$(id -g)" > "$HDIR/.env"
  echo "Connecting from the Hermes container (this is what the agent will see)…"
  # Internet/DNS test run ON the machine (Windows); encoded to avoid any quoting problem
  local enc; enc="$(printf '%s' '$c=New-Object Net.Sockets.TcpClient;try{$o=$c.ConnectAsync("1.1.1.1",443).Wait(4000)}catch{$o=$false};$c.Close();try{$d=[Net.Dns]::GetHostAddressesAsync("example.com").Wait(5000)}catch{$d=$false};"internet="+$o+" dns="+$d' | iconv -t UTF-16LE | base64 -w0)"
  local probe="command -v ssh >/dev/null || { echo 'ERROR: no ssh client in the Hermes image'; exit 3; }
S='ssh -n -F $INSIDE/config $name'
echo -n 'user    : '; \$S whoami || exit 4
echo -n 'machine : '; \$S hostname
if \$S 'whoami /groups' 2>/dev/null | grep -q 'S-1-5-32-544'; then echo 'WARNING: this user is a member of the Windows administrators'; fi
if \$S 'sudo -n true' >/dev/null 2>&1; then echo 'WARNING: sudo possible without a password'; else echo 'no sudo without a password: good'; fi
if timeout 15 ssh -F $INSIDE/config -W 127.0.0.1:22 $name < /dev/null 2>&1 | grep -q 'SSH-2.0'; then echo 'WARNING: SSH tunnel possible (port forwarding): see docs/agent-isolation.md'; else echo 'SSH tunnel refused: good'; fi
if \$S ver 2>/dev/null | grep -qi windows; then
  r=\$(\$S powershell -NoProfile -NonInteractive -EncodedCommand $enc 2>/dev/null | tr -d '\\r')
  case \"\$r\" in *internet=False*) echo 'Internet from the machine: blocked, good';; *) echo \"WARNING: the machine has Internet access (\$r): windows/outils/Isoler-machine-de-test.ps1\";; esac
  case \"\$r\" in *dns=False*) echo 'DNS from the machine: blocked, good';; *dns=True*) echo 'DNS from the machine: resolved (possible exit channel; unless -KeepDns was intended)';; esac
fi"
  # ssh refuses to run if the numeric id has no entry in /etc/passwd ("No user exists for uid 1000").
  # Here the image's normal start-up, which creates that user, is bypassed: so the entry is added to a copy of /etc/passwd.
  local pw; pw="$(mktemp)"; trap 'rm -f "$pw"' RETURN
  ( cd "$HDIR" && docker compose run --rm -T --entrypoint cat hermes /etc/passwd > "$pw" 2>/dev/null ) || true
  grep -q "^[^:]*:[^:]*:$(id -u):" "$pw" || echo "hermes-host:x:$(id -u):$(id -g):hermes:/opt/data:/bin/bash" >> "$pw"
  chmod 644 "$pw"
  ( cd "$HDIR" && timeout 120 docker compose run --rm -T --user "$(id -u):$(id -g)" -v "$pw:/etc/passwd:ro" --entrypoint bash hermes -lc "$probe" < /dev/null )   # < /dev/null and ssh -n: nothing must wait for the keyboard
  local rc=$?
  [ $rc -eq 0 ] && echo "OK. The agent connects to it with: ssh -F $INSIDE/config $name '…'" || echo "Failed (code $rc). Common causes: key not yet installed on the machine, firewall, changed fingerprint."
  return $rc
}

cmd_link() {
  local name="${1:?usage: lab remote link NAME PROJECT}" proj="${2:?usage: lab remote link NAME PROJECT}"
  valid_name "$name"; [[ "$proj" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || die "invalid project \"$proj\""
  exists "$name" || die "\"$name\" unknown (lab remote add first)"
  local P="$DATA/workspace/projects/$proj" F="$DATA/workspace/projects/$proj/AGENTS.md"
  # The agent writes in this folder: symbolic links are refused, they would make us write elsewhere on the AI machine.
  [ -d "$P" ] && [ ! -L "$P" ] || die "project \"$proj\" not found (or a symbolic link) in $DATA/workspace/projects"
  [ ! -L "$F" ] || die "$F is a symbolic link: refused for safety"
  local tpl="$HDIR/dev-template/AGENTS.md"
  [ -f "$tpl" ] || die "template not found: $tpl"
    # Marker: the current English one, or the French one written by earlier versions.
  if [ -f "$F" ] && grep -q -e "^Authorized test machine: \`$name\`" -e "^Machine de test autorisée : \`$name\`" "$F"; then echo "Already done for $proj."; return 0; fi
  {
    echo
    sed -n '/^## Test machines (SSH)/,$p' "$tpl" | sed "1a Authorized test machine: \`$name\`"
  } >> "$F"
  echo "Rules added to $F. Tell Hermes (in its session):"
  echo "  \"Read AGENTS.md again. You can connect to the machine $name with ssh -F /opt/data/ssh/config $name 'command'.\""
}

cmd_remove() {
  local name="${1:?usage: lab remote remove NAME}"; valid_name "$name"; exists "$name" || die "\"$name\" unknown"
  local host port; host="$(awk -v n="$name" '$1=="Host"{c=($2==n)} c&&$1=="HostName"{print $2}' "$SSHD/config")"
  port="$(awk -v n="$name" '$1=="Host"{c=($2==n)} c&&$1=="Port"{print $2}' "$SSHD/config")"
  awk -v n="$name" '$1=="Host"{skip=($2==n)} !skip' "$SSHD/config" > "$SSHD/config.new" && mv "$SSHD/config.new" "$SSHD/config"; chmod 600 "$SSHD/config"
  local pat="$host"; [ "$port" != 22 ] && pat="[$host]:$port"
  grep -vF -- "$pat " "$SSHD/known_hosts" > "$SSHD/known_hosts.new"; mv "$SSHD/known_hosts.new" "$SSHD/known_hosts"; chmod 600 "$SSHD/known_hosts"
  rm -f "$SSHD/id_ed25519_$name" "$SSHD/id_ed25519_$name.pub"
  echo "Removed on the AI machine side. Remember to remove the \"hermes@aibeast-$name\" line from ~/.ssh/authorized_keys on the machine, or to delete its user."
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;; show) shift; cmd_show "$@" ;; list) cmd_list ;; link) shift; cmd_link "$@" ;; test) shift; cmd_test "$@" ;; remove) shift; cmd_remove "$@" ;;
  *) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
