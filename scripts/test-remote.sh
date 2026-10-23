#!/usr/bin/env bash
# Tests scripts/remote.sh without a remote machine or a real Docker.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "  ✓ $1"; }; ko() { echo "  ✗ $1"; fail=1; }
export HERMES_DATA="$T/data"
mkdir -p "$T/bin"
if ! command -v ssh-keygen >/dev/null; then   # environment without OpenSSH: minimal simulation (the real command is tested where it exists)
  echo "  (ssh-keygen missing: simulated)"
  cat > "$T/bin/ssh-keygen" <<'S'
#!/usr/bin/env bash
f=""; c=""; l=""
while [ $# -gt 0 ]; do case "$1" in -f) f="$2"; shift;; -C) c="$2"; shift;; -lf) l=1; shift;; esac; shift; done
if [ -n "$l" ]; then echo "256 SHA256:SIMULATED host (ED25519)"; exit 0; fi
echo "PRIVATE-SIMULATED" > "$f"; echo "ssh-ed25519 AAAA$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n') $c" > "$f.pub"
S
  chmod +x "$T/bin/ssh-keygen"; export PATH="$T/bin:$PATH"
fi
R="$ROOT/scripts/remote.sh"
ssh-keygen -q -t ed25519 -N "" -f "$T/hostkey" && echo "vm.test ssh-ed25519 $(cut -d' ' -f2 "$T/hostkey.pub")" > "$T/scan"
export REMOTE_HOSTKEY_FILE="$T/scan"

out="$("$R" add vm1 hermes-test@vm.test --yes 2>&1)"; rc=$?
[ $rc = 0 ] && ok "add succeeds" || { ko "add (code $rc)"; echo "$out"; }
[ "$(stat -c %a "$HERMES_DATA/ssh/id_ed25519_vm1")" = 600 ] && ok "private key in 0600" || ko "key permissions"
[ "$(stat -c %a "$HERMES_DATA/ssh")" = 700 ] && ok "ssh folder in 0700" || ko "folder permissions"
[ "$(stat -c %a "$HERMES_DATA/ssh/config")" = 600 ] && ok "config in 0600" || ko "config permissions"
grep -q 'StrictHostKeyChecking yes' "$HERMES_DATA/ssh/config" && grep -q 'IdentitiesOnly yes' "$HERMES_DATA/ssh/config" && grep -q 'ForwardAgent no' "$HERMES_DATA/ssh/config" && ok "hardened config" || ko "config"
grep -q '^vm.test ssh-ed25519 ' "$HERMES_DATA/ssh/known_hosts" && ok "fingerprint pinned" || ko "known_hosts"
echo "$out" | grep -q "restrict,pty" && echo "$out" | grep -q "hermes@aibeast-vm1" && ok "restricted authorized_keys line shown" || ko "authorized_keys"
echo "$out" | grep -q "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub" && ok "asks to check the fingerprint" || ko "fingerprint check"
[ "$("$R" list | cut -f1)" = vm1 ] && ok "list" || ko "list"
"$R" add vm1 a@vm.test --yes >/dev/null 2>&1 && ko "duplicate accepted" || ok "duplicate refused"
# Injection into the ssh config file
for bad in 'x@h
 ProxyCommand touch /tmp/PWNED' 'x@h;id' 'x@h o' 'x@-h' 'x y@h' '@h' 'x@'; do
  "$R" add vm2 "$bad" --yes >/dev/null 2>&1 && ko "trapped target accepted: $bad" || true
done
"$R" add 'vm 3' x@h --yes >/dev/null 2>&1 && ko "trapped name accepted" || ok "trapped targets and names refused"
"$R" add vm2 x@vm.test 99999 --yes >/dev/null 2>&1 && ko "port 99999 accepted" || ok "invalid port refused"
[ ! -e /tmp/PWNED ] && [ "$(grep -c '^Host ' "$HERMES_DATA/ssh/config")" = 1 ] && ok "nothing was added to the config" || ko "config polluted"
# Wrong fingerprint / malformed answer
echo "garbage" > "$T/scan2"; REMOTE_HOSTKEY_FILE="$T/scan2" "$R" add vm4 x@vm.test --yes >/dev/null 2>&1 && ko "malformed answer accepted" || ok "malformed answer refused"
echo n | "$R" add vm5 x@vm.test >/dev/null 2>&1 && ko "unconfirmed fingerprint accepted" || ok "unconfirmed fingerprint: aborted"
[ ! -e "$HERMES_DATA/ssh/id_ed25519_vm5" ] && ok "no key created after aborting" || ko "key created despite aborting"
# Non-standard port
"$R" add vm6 x@vm.test 2222 --yes >/dev/null 2>&1; echo "[vm.test]:2222 ssh-ed25519 $(cut -d' ' -f2 "$T/hostkey.pub")" > /dev/null
grep -q '^\[vm.test\]:2222 ' "$HERMES_DATA/ssh/known_hosts" && ok "port 2222: [host]:port form" || ko "known_hosts port"
# test: simulated docker
printf '#!/bin/sh\necho "STUB docker $*"\nexit 0\n' > "$T/bin/docker"; chmod +x "$T/bin/docker"
out="$(PATH="$T/bin:$PATH" "$R" test vm1 2>&1)"
echo "$out" | grep -q -- "ssh -F /opt/data/ssh/config vm1" && echo "$out" | grep -q "S-1-5-32-544" && echo "$out" | grep -q "ssh -n -F" && echo "$out" | grep -q "/etc/passwd:ro" && ok "test: ssh run in the container (passwd entry added), Linux and Windows checks" || { ko "test"; echo "$out"; }
rm -f "$ROOT/hermes/.env" 2>/dev/null
# Windows
outw="$("$R" add pcwin hermes-test@vm.test --windows --yes 2>&1)"
echo "$outw" | grep -q "New-LocalUser -Name 'hermes-test'" && echo "$outw" | grep -q "restrict,pty.* ssh-ed25519 .* hermes@aibeast-pcwin" && ok "--windows: PowerShell script with the restricted line" || { ko "--windows"; echo "$outw"; }
echo "$outw" | grep -q "C:.ProgramData.ssh.hermes-test_authorized_keys" && echo "$outw" | grep -q "PasswordAuthentication no" && echo "$outw" | grep -q "Get-LocalGroup -SID S-1-5-32-545" && ok "--windows: plain user, key outside the profile" || ko "--windows content"
echo "$outw" | grep -q "New-Guid" && ! echo "$outw" | grep -q "NewGuid" && ok "--windows: password generated without ::" || ko "New-Guid"
echo "$outw" | grep -q "S-1-5-32-544" && echo "$outw" | grep -q "S-1-5-32-545" && ! echo "$outw" | grep -q "'Administrators:F'\|-Group 'Users'" && ok "--windows: language-independent (SID)" || ko "SID"
echo "$outw" | grep -q "@USER@\|@LINE@" && ko "placeholders not replaced" || ok "--windows: placeholders replaced"
shw="$("$R" show pcwin --windows 2>&1)"
[ "$(echo "$shw" | grep -c '^  icacls')" -ge 5 ] && echo "$shw" | grep -q "icacls \$f /grant '\*S-1-5-18:F'" && ok "--windows: one right per icacls command" || ko "separate icacls"
echo "$shw" | grep -q "hermes@aibeast-pcwin" && echo "$shw" | grep -q "New-LocalUser -Name 'hermes-test'" && ok "show: shows the block again with the key and the name" || { ko "show"; echo "$shw"; }
"$R" show unknown >/dev/null 2>&1 && ko "show unknown machine" || ok "show: unknown machine refused"
"$R" remove pcwin >/dev/null 2>&1
# link: adds the rules to an existing project
mkdir -p "$HERMES_DATA/workspace/projects/test_project"; echo "# Project" > "$HERMES_DATA/workspace/projects/test_project/AGENTS.md"
"$R" add vm7 x@vm.test --yes >/dev/null 2>&1
"$R" link vm7 test_project >/dev/null 2>&1; F="$HERMES_DATA/workspace/projects/test_project/AGENTS.md"
grep -q '^Authorized test machine: `vm7`' "$F" && grep -q "ssh -F /opt/data/ssh/config NAME" "$F" && head -1 "$F" | grep -q '^# Project' && ok "link: rules added without overwriting what exists" || ko "link"
"$R" link vm7 test_project >/dev/null 2>&1; [ "$(grep -c 'Authorized test machine' "$F")" = 1 ] && ok "link: idempotent" || ko "repeated link"
# a project linked by an earlier (French) version must not get the rules twice
mkdir -p "$HERMES_DATA/workspace/projects/old_project"; F2="$HERMES_DATA/workspace/projects/old_project/AGENTS.md"
printf '# Old\n\n## Machines de test (SSH)\nMachine de test autorisée : `vm7`\n' > "$F2"
"$R" link vm7 old_project >/dev/null 2>&1; ! grep -q 'Authorized test machine' "$F2" && ok "link: former French marker recognised" || ko "link: French marker"
"$R" link unknown test_project >/dev/null 2>&1 && ko "link unknown machine" || ok "link: unknown machine refused"
"$R" link vm7 'x/../y' >/dev/null 2>&1 && ko "link trapped project" || ok "link: trapped project refused"
mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$HERMES_DATA/workspace/projects/lnk"; "$R" link vm7 lnk >/dev/null 2>&1 && ko "link folder-link accepted" || ok "link: folder-link refused"
mkdir -p "$HERMES_DATA/workspace/projects/p2"; ln -s "$T/target" "$HERMES_DATA/workspace/projects/p2/AGENTS.md"; "$R" link vm7 p2 >/dev/null 2>&1; [ ! -e "$T/target" ] && ok "link: AGENTS.md-link refused, nothing written elsewhere" || ko "write through a link"
# remove
"$R" remove vm1 >/dev/null 2>&1
[ ! -e "$HERMES_DATA/ssh/id_ed25519_vm1" ] && ! grep -q '^Host vm1$' "$HERMES_DATA/ssh/config" && ok "remove: key and entry removed" || ko "remove"
grep -q '^\[vm.test\]:2222 ' "$HERMES_DATA/ssh/known_hosts" && ok "remove: the other machine stays" || ko "remove deleted too much"
[ $fail = 0 ] && echo "All remote.sh tests pass." || { echo "FAILURES"; exit 1; }
