#!/usr/bin/env bash
# Teste scripts/remote.sh sans machine distante ni Docker réel.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "  ✓ $1"; }; ko() { echo "  ✗ $1"; fail=1; }
export HERMES_DATA="$T/data"
mkdir -p "$T/bin"
if ! command -v ssh-keygen >/dev/null; then   # environnement sans OpenSSH : simulation minimale (la vraie commande est testée là où elle existe)
  echo "  (ssh-keygen absent : simulé)"
  cat > "$T/bin/ssh-keygen" <<'S'
#!/usr/bin/env bash
f=""; c=""; l=""
while [ $# -gt 0 ]; do case "$1" in -f) f="$2"; shift;; -C) c="$2"; shift;; -lf) l=1; shift;; esac; shift; done
if [ -n "$l" ]; then echo "256 SHA256:SIMULE host (ED25519)"; exit 0; fi
echo "PRIVATE-SIMULE" > "$f"; echo "ssh-ed25519 AAAA$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n') $c" > "$f.pub"
S
  chmod +x "$T/bin/ssh-keygen"; export PATH="$T/bin:$PATH"
fi
R="$ROOT/scripts/remote.sh"
ssh-keygen -q -t ed25519 -N "" -f "$T/hostkey" && echo "vm.test ssh-ed25519 $(cut -d' ' -f2 "$T/hostkey.pub")" > "$T/scan"
export REMOTE_HOSTKEY_FILE="$T/scan"

out="$("$R" add vm1 hermes-test@vm.test --yes 2>&1)"; rc=$?
[ $rc = 0 ] && ok "add réussit" || { ko "add (code $rc)"; echo "$out"; }
[ "$(stat -c %a "$HERMES_DATA/ssh/id_ed25519_vm1")" = 600 ] && ok "clé privée en 0600" || ko "droits de la clé"
[ "$(stat -c %a "$HERMES_DATA/ssh")" = 700 ] && ok "dossier ssh en 0700" || ko "droits du dossier"
[ "$(stat -c %a "$HERMES_DATA/ssh/config")" = 600 ] && ok "config en 0600" || ko "droits de la config"
grep -q 'StrictHostKeyChecking yes' "$HERMES_DATA/ssh/config" && grep -q 'IdentitiesOnly yes' "$HERMES_DATA/ssh/config" && grep -q 'ForwardAgent no' "$HERMES_DATA/ssh/config" && ok "config durcie" || ko "config"
grep -q '^vm.test ssh-ed25519 ' "$HERMES_DATA/ssh/known_hosts" && ok "empreinte épinglée" || ko "known_hosts"
echo "$out" | grep -q "restrict,pty" && echo "$out" | grep -q "hermes@aibeast-vm1" && ok "ligne authorized_keys restreinte affichée" || ko "authorized_keys"
echo "$out" | grep -q "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub" && ok "demande de vérifier l'empreinte" || ko "vérification de l'empreinte"
[ "$("$R" list | cut -f1)" = vm1 ] && ok "list" || ko "list"
"$R" add vm1 a@vm.test --yes >/dev/null 2>&1 && ko "doublon accepté" || ok "doublon refusé"
# Injection dans le fichier de config ssh
for bad in 'x@h
 ProxyCommand touch /tmp/PWNED' 'x@h;id' 'x@h o' 'x@-h' 'x y@h' '@h' 'x@'; do
  "$R" add vm2 "$bad" --yes >/dev/null 2>&1 && ko "cible piégée acceptée : $bad" || true
done
"$R" add 'vm 3' x@h --yes >/dev/null 2>&1 && ko "nom piégé accepté" || ok "cibles et noms piégés refusés"
"$R" add vm2 x@vm.test 99999 --yes >/dev/null 2>&1 && ko "port 99999 accepté" || ok "port invalide refusé"
[ ! -e /tmp/PWNED ] && [ "$(grep -c '^Host ' "$HERMES_DATA/ssh/config")" = 1 ] && ok "rien n'a été ajouté à la config" || ko "config polluée"
# Mauvaise empreinte / réponse non conforme
echo "garbage" > "$T/scan2"; REMOTE_HOSTKEY_FILE="$T/scan2" "$R" add vm4 x@vm.test --yes >/dev/null 2>&1 && ko "réponse non conforme acceptée" || ok "réponse non conforme refusée"
echo n | "$R" add vm5 x@vm.test >/dev/null 2>&1 && ko "empreinte non confirmée acceptée" || ok "empreinte non confirmée : abandon"
[ ! -e "$HERMES_DATA/ssh/id_ed25519_vm5" ] && ok "aucune clé créée après abandon" || ko "clé créée malgré l'abandon"
# Port non standard
"$R" add vm6 x@vm.test 2222 --yes >/dev/null 2>&1; echo "[vm.test]:2222 ssh-ed25519 $(cut -d' ' -f2 "$T/hostkey.pub")" > /dev/null
grep -q '^\[vm.test\]:2222 ' "$HERMES_DATA/ssh/known_hosts" && ok "port 2222 : forme [hôte]:port" || ko "known_hosts port"
# test : docker simulé
printf '#!/bin/sh\necho "STUB docker $*"\nexit 0\n' > "$T/bin/docker"; chmod +x "$T/bin/docker"
out="$(PATH="$T/bin:$PATH" "$R" test vm1 2>&1)"
echo "$out" | grep -q -- "ssh -F /opt/data/ssh/config vm1" && echo "$out" | grep -q "S-1-5-32-544" && echo "$out" | grep -q "ssh -n -F" && echo "$out" | grep -q "/etc/passwd:ro" && ok "test : ssh lancé dans le conteneur (entrée passwd ajoutée), contrôle Linux et Windows" || { ko "test"; echo "$out"; }
rm -f "$ROOT/hermes/.env" 2>/dev/null
# Windows
outw="$("$R" add pcwin hermes-test@vm.test --windows --yes 2>&1)"
echo "$outw" | grep -q "New-LocalUser -Name 'hermes-test'" && echo "$outw" | grep -q "restrict,pty.* ssh-ed25519 .* hermes@aibeast-pcwin" && ok "--windows : script PowerShell avec la ligne restreinte" || { ko "--windows"; echo "$outw"; }
echo "$outw" | grep -q "C:.ProgramData.ssh.hermes-test_authorized_keys" && echo "$outw" | grep -q "PasswordAuthentication no" && echo "$outw" | grep -q "Get-LocalGroup -SID S-1-5-32-545" && ok "--windows : utilisateur simple, clé hors profil" || ko "--windows contenu"
echo "$outw" | grep -q "New-Guid" && ! echo "$outw" | grep -q "NewGuid" && ok "--windows : génération du mot de passe sans ::" || ko "New-Guid"
echo "$outw" | grep -q "S-1-5-32-544" && echo "$outw" | grep -q "S-1-5-32-545" && ! echo "$outw" | grep -q "'Administrators:F'\|-Group 'Users'" && ok "--windows : indépendant de la langue (SID)" || ko "SID"
echo "$outw" | grep -q "@USER@\|@LINE@" && ko "marqueurs non remplacés" || ok "--windows : marqueurs remplacés"
shw="$("$R" show pcwin --windows 2>&1)"
[ "$(echo "$shw" | grep -c '^  icacls')" -ge 5 ] && echo "$shw" | grep -q "icacls \$f /grant '\*S-1-5-18:F'" && ok "--windows : un droit par commande icacls" || ko "icacls séparés"
echo "$shw" | grep -q "hermes@aibeast-pcwin" && echo "$shw" | grep -q "New-LocalUser -Name 'hermes-test'" && ok "show : réaffiche le bloc avec la clé et le nom" || { ko "show"; echo "$shw"; }
"$R" show inconnue >/dev/null 2>&1 && ko "show machine inconnue" || ok "show : machine inconnue refusée"
"$R" remove pcwin >/dev/null 2>&1
# link : ajoute les règles à un projet existant
mkdir -p "$HERMES_DATA/workspace/projects/projet_test"; echo "# Projet" > "$HERMES_DATA/workspace/projects/projet_test/AGENTS.md"
"$R" add vm7 x@vm.test --yes >/dev/null 2>&1
"$R" link vm7 projet_test >/dev/null 2>&1; F="$HERMES_DATA/workspace/projects/projet_test/AGENTS.md"
grep -q '^Machine de test autorisée : `vm7`' "$F" && grep -q "ssh -F /opt/data/ssh/config NOM" "$F" && head -1 "$F" | grep -q '^# Projet' && ok "link : règles ajoutées sans écraser l'existant" || ko "link"
"$R" link vm7 projet_test >/dev/null 2>&1; [ "$(grep -c 'Machine de test autorisée' "$F")" = 1 ] && ok "link : idempotent" || ko "link répété"
"$R" link inconnue projet_test >/dev/null 2>&1 && ko "link machine inconnue" || ok "link : machine inconnue refusée"
"$R" link vm7 'x/../y' >/dev/null 2>&1 && ko "link projet piégé" || ok "link : projet piégé refusé"
mkdir -p "$T/ailleurs"; ln -s "$T/ailleurs" "$HERMES_DATA/workspace/projects/lien"; "$R" link vm7 lien >/dev/null 2>&1 && ko "link dossier-lien accepté" || ok "link : dossier-lien refusé"
mkdir -p "$HERMES_DATA/workspace/projects/p2"; ln -s "$T/cible" "$HERMES_DATA/workspace/projects/p2/AGENTS.md"; "$R" link vm7 p2 >/dev/null 2>&1; [ ! -e "$T/cible" ] && ok "link : AGENTS.md-lien refusé, rien écrit ailleurs" || ko "écriture via lien"
# remove
"$R" remove vm1 >/dev/null 2>&1
[ ! -e "$HERMES_DATA/ssh/id_ed25519_vm1" ] && ! grep -q '^Host vm1$' "$HERMES_DATA/ssh/config" && ok "remove : clé et entrée supprimées" || ko "remove"
grep -q '^\[vm.test\]:2222 ' "$HERMES_DATA/ssh/known_hosts" && ok "remove : l'autre machine reste" || ko "remove a trop supprimé"
[ $fail = 0 ] && echo "Tous les tests de remote.sh passent." || { echo "ÉCHECS"; exit 1; }
