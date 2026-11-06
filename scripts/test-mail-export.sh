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

echo "· lab mail (scripts/mail-agent.sh, fake docker, fake lab and 5-hermes.sh)"
M="$T/m"; mkdir -p "$M/scripts" "$M/hermes/mail-template" "$M/bin" "$M/data" "$M/inbox"
cp "$ROOT/scripts/mail-agent.sh" "$M/scripts/"; cp "$ROOT/hermes/mail-template/AGENTS.md" "$M/hermes/mail-template/"
printf '#!/usr/bin/env bash\necho test-model\n' > "$M/lab"
printf '#!/usr/bin/env bash\necho "ARGS=$* MAIL=${HERMES_MAIL_DIR:-} WORK=${HERMES_WORKDIR:-} SERIAL=${HERMES_SERIAL:-} EFFORT=$(grep -h reasoning_effort ${HERMES_DATA:-/nonexistent}/config.yaml 2>/dev/null | tr -d " ")" > "$FAKE_OUT"\n' > "$M/5-hermes.sh"
printf '#!/usr/bin/env bash\n[ "$1" = exec ] && printf "NAME ID SIZE\\ntest-model x 1GB\\n"\nexit 0\n' > "$M/bin/docker"
chmod +x "$M/lab" "$M/5-hermes.sh" "$M/bin/docker" "$M/scripts/mail-agent.sh"
mrun() { rm -f "$T/mail-out"; ( env FAKE_OUT="$T/mail-out" PATH="$M/bin:$PATH" HERMES_DATA="$M/data" LAB_MAIL_DIR="$M/inbox" "$@" "$M/scripts/mail-agent.sh" $MARGS >"$T/mail-msg" 2>&1 ); echo $?; }
MARGS=""; rc=$(mrun)
[ "$rc" = 0 ] && grep -q "ARGS=test-model MAIL=$M/inbox WORK=/opt/data/workspace/mail SERIAL=/nonexistent" "$T/mail-out" && ok "lab mail: read-only mail folder, own workspace, no serial device" || ko "lab mail args: rc=$rc $(cat "$T/mail-out" "$T/mail-msg" 2>&1)"
grep -q "UNTRUSTED EMAIL BODY" "$M/data/workspace/mail/AGENTS.md" && ok "lab mail: AGENTS.md with the untrusted-mail rule created" || ko "no AGENTS.md rule"
echo "my own rules" > "$M/data/workspace/mail/AGENTS.md"; mrun >/dev/null
grep -q "my own rules" "$M/data/workspace/mail/AGENTS.md" && ok "lab mail: an existing AGENTS.md is kept" || ko "AGENTS.md overwritten"
rc=$(mrun LAB_AGENT_SSH_ALLOW=192.0.2.60)
[ "$rc" != 0 ] && [ ! -e "$T/mail-out" ] && grep -q "LAB_AGENT_SSH_ALLOW" "$T/mail-msg" && ok "lab mail: refuses while LAB_AGENT_SSH_ALLOW is set" || ko "did not refuse: rc=$rc"
MARGS="--force"; rc=$(mrun LAB_AGENT_SSH_ALLOW=192.0.2.60)
[ "$rc" = 0 ] && [ -e "$T/mail-out" ] && ok "lab mail --force starts anyway" || ko "--force: rc=$rc"
MARGS=""; rc=$(mrun LAB_MAIL_DIR="$T/absent")
[ "$rc" != 0 ] && ok "lab mail: refuses a missing mail folder" || ko "accepted a missing mail folder"

# reasoning level: set for the session only, then put back exactly (three shapes of config.yaml, then leftover repair)
C="$M/data/config.yaml"; MARGS=""
printf 'model:\n  default: test-model\ndelegation:\n  max_iterations: 60\n' > "$C"; cp "$C" "$T/cfg.a"
rc=$(mrun); grep -q 'EFFORT=reasoning_effort:low' "$T/mail-out" && cmp -s "$C" "$T/cfg.a" && [ ! -e "$M/data/.mail-reasoning-undo" ] \
  && ok "reasoning: low during the session, config.yaml back to the byte (no agent block)" || ko "append case: rc=$rc $(cat "$T/mail-out"; diff "$T/cfg.a" "$C")"
printf 'agent:\n  max_turns: 5\nmodel:\n  default: test-model\n' > "$C"; cp "$C" "$T/cfg.b"
rc=$(mrun); grep -q 'EFFORT=reasoning_effort:low' "$T/mail-out" && cmp -s "$C" "$T/cfg.b" \
  && ok "reasoning: back to the byte (agent block without reasoning_effort)" || ko "insert case: $(cat "$T/mail-out"; diff "$T/cfg.b" "$C")"
printf 'agent:\n  max_turns: 5\n  reasoning_effort: high\n  other: 1\nmodel:\n  default: test-model\n' > "$C"; cp "$C" "$T/cfg.c"
rc=$(mrun); grep -q 'EFFORT=reasoning_effort:low' "$T/mail-out" && cmp -s "$C" "$T/cfg.c" \
  && ok "reasoning: back to the previous value (high) afterwards" || ko "replace case: $(cat "$T/mail-out"; diff "$T/cfg.c" "$C")"
rc=$(mrun LAB_MAIL_REASONING=medium); grep -q 'EFFORT=reasoning_effort:medium' "$T/mail-out" && cmp -s "$C" "$T/cfg.c" && ok "LAB_MAIL_REASONING is honoured" || ko "LAB_MAIL_REASONING: $(cat "$T/mail-out")"
rc=$(mrun LAB_MAIL_REASONING=off); grep -q 'EFFORT=reasoning_effort:high' "$T/mail-out" && cmp -s "$C" "$T/cfg.c" && ok "LAB_MAIL_REASONING=off leaves config.yaml alone" || ko "off: $(cat "$T/mail-out")"
rc=$(mrun LAB_MAIL_REASONING=banana); [ "$rc" != 0 ] && ok "an invalid LAB_MAIL_REASONING is refused" || ko "accepted banana"
# leftover of a killed session: simulate by running set_reasoning's effect by hand, then start again
printf 'model:\n  default: test-model\n' > "$T/cfg.d"; printf 'model:\n  default: test-model\n\nagent:\n  reasoning_effort: low\n' > "$C"; printf 'append|%s|low\n' "$(wc -c < "$T/cfg.d")" > "$M/data/.mail-reasoning-undo"
rc=$(mrun LAB_MAIL_REASONING=off); [ ! -e "$M/data/.mail-reasoning-undo" ] && cmp -s "$C" "$T/cfg.d" && ok "a leftover of a killed session is repaired at the next start" || ko "leftover: $(cat "$C")"
# a failing Hermes session still restores
printf 'model:\n  default: test-model\n' > "$C"; cp "$C" "$T/cfg.e"; printf '#!/usr/bin/env bash\nexit 7\n' > "$M/5-hermes.sh"
rc=$(mrun); [ "$rc" = 7 ] && cmp -s "$C" "$T/cfg.e" && ok "reasoning restored and exit code kept when the session fails" || ko "failing session: rc=$rc"

echo "· PowerShell scripts: pure ASCII (Windows PowerShell 5.1 reads a BOM-less file as ANSI and garbles other characters)"
if grep -nP '[^\x00-\x7F]' "$ROOT"/mail-export/windows/*.ps1 >/dev/null; then ko "non-ASCII character in a .ps1 file (use \\uXXXX escapes)"; else ok "no non-ASCII character in the .ps1 files"; fi

echo; [ $fail -eq 0 ] && echo "All good" || { echo "FAILURES"; exit 1; }
