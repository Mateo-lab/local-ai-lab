#!/usr/bin/env bash
# Offline tests of the Linux side of the Outlook export (no root, no Docker, no sshd, no Outlook):
#   - mail-export/linux/purge-mail-exports.sh (what it deletes, what it keeps, the refusals);
#   - mail-export/linux/setup-mailpush.sh in DRY-RUN mode (nothing is created) and its key checks;
#   - the HERMES_MAIL_DIR / serial compose arguments built by 5-hermes.sh (fake docker).
# The PowerShell side (mail-export/windows) needs Windows + Outlook and is NOT covered here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "  ✓ $1"; }; ko() { echo "  ✗ $1"; fail=1; }
P="$ROOT/mail-export/linux/purge-mail-exports.sh"; S="$ROOT/mail-export/linux/setup-mailpush.sh"

echo "· purge: dry run, then apply"
D="$T/srv/mail-in/inbox"; mkdir -p "$D/old.attachments" "$D/new.attachments" "$T/outside"
touch -d '40 days ago' "$D/old mail.md" "$D/_export-status.json" "$D/old.attachments/a.pdf"
touch -d '5 days ago' "$D/recent.md"; touch -d '2 days ago' "$D/.tmp-stale.md"; touch "$D/.tmp-fresh.md" "$D/new.attachments/b.txt"
touch -d '60 days ago' "$T/outside/precious.md"; ln -s "$T/outside/precious.md" "$D/link.md"
out="$("$P" --dir "$D" --days 30 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "dry run exits 0" || ko "dry run rc=$rc: $out"
grep -q "old mail.md" <<<"$out" && ok "dry run lists the old mail" || ko "dry run output: $out"
[ -e "$D/old mail.md" ] && ok "dry run deleted nothing" || ko "dry run deleted a file"
out="$("$P" --dir "$D" --days 30 --apply 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "apply exits 0" || ko "apply rc=$rc: $out"
[ ! -e "$D/old mail.md" ] && ok "old mail (name with a space) deleted" || ko "old mail kept"
[ ! -e "$D/old.attachments/a.pdf" ] && [ ! -d "$D/old.attachments" ] && ok "old attachment and its empty folder deleted" || ko "old attachments kept"
[ ! -e "$D/.tmp-stale.md" ] && ok "stale .tmp- upload deleted" || ko "stale .tmp- kept"
[ -e "$D/recent.md" ] && [ -e "$D/.tmp-fresh.md" ] && [ -e "$D/new.attachments/b.txt" ] && ok "recent files kept" || ko "a recent file was deleted"
[ -e "$D/_export-status.json" ] && ok "heartbeat file kept even when old" || ko "heartbeat deleted"
[ -e "$T/outside/precious.md" ] && ok "symlink target outside the folder untouched" || ko "file outside deleted!"
for bad in / /srv /tmp /home "$T" ; do
  "$P" --dir "$bad" --days 30 --apply >/dev/null 2>&1 && ko "accepted $bad" || ok "refuses $bad"
done
"$P" --dir "$D" --days 0 >/dev/null 2>&1 && ko "accepted --days 0" || ok "refuses --days 0"
"$P" --dir "$D" --days abc >/dev/null 2>&1 && ko "accepted --days abc" || ok "refuses --days abc"

echo "· setup-mailpush.sh (dry run)"
KEY="$T/key.pub"; echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFake user@pc' > "$KEY"
# the real file may already exist (setup applied on this machine): compare before/after instead of testing absence
AK=/etc/ssh/authorized_keys.d/mailpush; before="$(stat -c '%Y %s' "$AK" 2>/dev/null || echo absent)"
out="$("$S" --pubkey-file "$KEY" --from 192.0.2.10 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "dry run exits 0 without root" || ko "dry run rc=$rc: $out"
grep -q 'restrict,from="192.0.2.10" ssh-ed25519 AAAA' <<<"$out" && ok "authorized_keys line restricted" || ko "no restricted line"
grep -q 'ChrootDirectory /srv/mail-in' <<<"$out" && grep -q 'ForceCommand internal-sftp' <<<"$out" && ok "chroot + internal-sftp" || ko "sshd block"
grep -q 'AllowTcpForwarding no' <<<"$out" && grep -q 'PermitTTY no' <<<"$out" && ok "no tunnel, no tty" || ko "forwarding/tty not disabled"
grep -q 'user@pc' <<<"$out" && ko "the key comment leaked into the line" || ok "key comment dropped"
after="$(stat -c '%Y %s' "$AK" 2>/dev/null || echo absent)"
[ "$before" = "$after" ] && ok "dry run changed nothing ($AK)" || ko "dry run modified $AK"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nxxx\n-----END OPENSSH PRIVATE KEY-----\n' > "$T/priv"
"$S" --pubkey-file "$T/priv" >/dev/null 2>&1 && ko "accepted a private key" || ok "refuses a private key file"
printf 'ssh-ed25519 AAAA one\nssh-ed25519 BBBB two\n' > "$T/two.pub"
"$S" --pubkey-file "$T/two.pub" >/dev/null 2>&1 && ko "accepted two keys" || ok "refuses a file with two keys"
"$S" --pubkey-file "$KEY" --from 'x" command="evil' >/dev/null 2>&1 && ko "accepted a quote in --from" || ok "refuses an injected --from"

echo "· 5-hermes.sh compose arguments (fake docker)"
mkdir -p "$T/lab/hermes" "$T/lab/bin" "$T/inbox"
cp "$ROOT/5-hermes.sh" "$T/lab/"; cp "$ROOT"/hermes/{docker-compose.yml,mail.yml,serial.yml,config.yaml.example} "$T/lab/hermes/"
cat > "$T/lab/bin/docker" <<'S'
#!/usr/bin/env bash
case "$1" in
  compose) echo "$*" >> "$FAKE_LOG" ;;
  exec) echo 65536 ;;
esac
exit 0
S
chmod +x "$T/lab/bin/docker"
run() { : > "$T/log"; ( cd "$T/lab" && env FAKE_LOG="$T/log" PATH="$T/lab/bin:$PATH" HERMES_SERIAL=/nonexistent "$@" ./5-hermes.sh some-model >/dev/null 2>&1 ); echo $?; }
rc=$(run); l="$(cat "$T/log")"
[ "$rc" = 0 ] && ! grep -q -- '-f ' <<<"$l" && ok "default: no -f override" || ko "default args: rc=$rc $l"
rc=$(run HERMES_MAIL_DIR="$T/inbox"); l="$(cat "$T/log")"
[ "$rc" = 0 ] && grep -q -- '-f docker-compose.yml -f mail.yml run' <<<"$l" && ok "HERMES_MAIL_DIR adds mail.yml" || ko "mail args: rc=$rc $l"
rc=$(run HERMES_MAIL_DIR="$T/inbox" HERMES_SERIAL=/dev/null); l="$(cat "$T/log")"
[ "$rc" = 0 ] && grep -q -- '-f docker-compose.yml -f serial.yml -f mail.yml run' <<<"$l" && ok "serial + mail combine" || ko "combined args: rc=$rc $l"
rc=$(run HERMES_MAIL_DIR="$T/nope")
[ "$rc" != 0 ] && ok "refuses a missing HERMES_MAIL_DIR" || ko "accepted a missing folder"

echo "· PowerShell scripts: pure ASCII (Windows PowerShell 5.1 reads a BOM-less file as ANSI and garbles other characters)"
if grep -nP '[^\x00-\x7F]' "$ROOT"/mail-export/windows/*.ps1 >/dev/null; then ko "non-ASCII character in a .ps1 file (use \\uXXXX escapes)"; else ok "no non-ASCII character in the .ps1 files"; fi

echo; [ $fail -eq 0 ] && echo "All good" || { echo "FAILURES"; exit 1; }
