#!/usr/bin/env bash
# Prepares the AI machine to RECEIVE the daily Outlook export (see docs/mail-export.md).
#
#   sudo ./setup-mailpush.sh --pubkey-file mail_export_ed25519.pub [--from PC_ADDRESS] [--base /srv/mail-in] [--apply]
#
# Without --apply it only PRINTS what it would do (dry run). With --apply it:
#   1. creates the system user "mailpush" (no shell, no password);
#   2. creates BASE (root-owned, the SFTP chroot) and BASE/inbox (owned by mailpush, world-readable: the Hermes container
#      reads it as another user, read-only);
#   3. writes /etc/ssh/authorized_keys.d/mailpush:  restrict[,from="PC_ADDRESS"] <your PUBLIC key>;
#   4. writes /etc/ssh/sshd_config.d/20-mail-export.conf (Match User mailpush: chroot + internal-sftp only, no tunnel,
#      no tty, no password), checks it with `sshd -t` and REMOVES it again if the check fails;
#   5. installs the purge script (/usr/local/sbin/purge-mail-exports) and the systemd service + timer (not enabled).
# It does NOT reload sshd: do it yourself after reading the result (sudo systemctl reload ssh).
# It never reads or writes a private key: only pass the .pub file.
set -euo pipefail
BASE=/srv/mail-in; PUB=""; FROM=""; APPLY=0; U=mailpush
SSHD_DIR="${MAIL_SSHD_CONF_DIR:-/etc/ssh/sshd_config.d}"; AK_DIR="${MAIL_AKEYS_DIR:-/etc/ssh/authorized_keys.d}"
SBIN="${MAIL_SBIN_DIR:-/usr/local/sbin}"; UNITS="${MAIL_UNIT_DIR:-/etc/systemd/system}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --pubkey-file) PUB="${2:?}"; shift 2 ;;
    --from) FROM="${2:?}"; shift 2 ;;
    --base) BASE="${2:?}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PUB" ] || { echo "--pubkey-file is required (the PUBLIC key of the PC)" >&2; exit 2; }
[ -f "$PUB" ] || { echo "File not found: $PUB" >&2; exit 2; }
grep -q 'PRIVATE KEY' "$PUB" && { echo "This file contains a PRIVATE key. Stop: never copy a private key to the server; pass the .pub file." >&2; exit 2; }
[ "$(grep -cv '^[[:space:]]*\(#.*\)\?$' "$PUB")" = 1 ] || { echo "The public key file must contain exactly one key line." >&2; exit 2; }
KTYPE="$(awk 'NF{print $1; exit}' "$PUB")"; KBLOB="$(awk 'NF{print $2; exit}' "$PUB")"
case "$KTYPE" in ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com) ;; *) echo "Unrecognised key type '$KTYPE' (expected a line like: ssh-ed25519 AAAA… comment)" >&2; exit 2 ;; esac
[[ "$KBLOB" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo "The key does not look like a valid public key." >&2; exit 2; }
if [ -n "$FROM" ]; then [[ "$FROM" =~ ^[0-9A-Fa-f.:/,*?!-]+$ ]] || { echo "--from: invalid address pattern" >&2; exit 2; }; fi
case "$BASE" in /*) ;; *) echo "--base must be an absolute path" >&2; exit 2 ;; esac
if [ "$APPLY" = 1 ] && [ "$(id -u)" != 0 ]; then echo "--apply needs root: sudo $0 …" >&2; exit 1; fi

OPTS="restrict"; [ -n "$FROM" ] && OPTS="restrict,from=\"$FROM\""
AKLINE="$OPTS $KTYPE $KBLOB mail-export"
CONF="# Written by mail-export/linux/setup-mailpush.sh — receives the daily Outlook export, SFTP only.
Match User $U
    ChrootDirectory $BASE
    ForceCommand internal-sftp -u 0022
    AuthorizedKeysFile $AK_DIR/$U
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowStreamLocalForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitTTY no
    GatewayPorts no
"
say() { echo "• $*"; }
run() { if [ "$APPLY" = 1 ]; then "$@"; else echo "  (dry run) $*"; fi }
[ "$APPLY" = 1 ] && echo "APPLY mode" || echo "DRY RUN — nothing will be changed (add --apply)"
echo

say "user '$U' (system account, no login shell)"
if id "$U" >/dev/null 2>&1; then echo "  already exists"; else run useradd --system --user-group --home-dir "$BASE" --shell /usr/sbin/nologin "$U"; fi
say "folders: $BASE (root-owned chroot) and $BASE/inbox (owned by $U)"
run install -d -m 0755 -o root -g root "$BASE"
run install -d -m 0755 -o "$U" -g "$U" "$BASE/inbox"
say "authorized key file $AK_DIR/$U"
echo "  content: $AKLINE"
run install -d -m 0755 -o root -g root "$AK_DIR"
if [ "$APPLY" = 1 ]; then printf '%s\n' "$AKLINE" > "$AK_DIR/$U"; chown root:root "$AK_DIR/$U"; chmod 0644 "$AK_DIR/$U"; fi
say "sshd drop-in $SSHD_DIR/20-mail-export.conf"
printf '%s\n' "$CONF" | sed 's/^/  | /'
SSHD_BIN="$(command -v sshd || ls /usr/sbin/sshd 2>/dev/null || true)"
if [ "$APPLY" = 1 ]; then
  install -d -m 0755 "$SSHD_DIR"
  [ -f "$SSHD_DIR/20-mail-export.conf" ] && cp -p "$SSHD_DIR/20-mail-export.conf" "$SSHD_DIR/20-mail-export.conf.avant-$(date +%Y%m%d-%H%M%S)"
  printf '%s\n' "$CONF" > "$SSHD_DIR/20-mail-export.conf"; chmod 0644 "$SSHD_DIR/20-mail-export.conf"
  if [ -n "$SSHD_BIN" ]; then
    if ! "$SSHD_BIN" -t 2>/tmp/mail-export-sshd-check.$$; then
      echo "sshd -t FAILED, drop-in removed:" >&2; cat /tmp/mail-export-sshd-check.$$ >&2; rm -f "$SSHD_DIR/20-mail-export.conf" /tmp/mail-export-sshd-check.$$; exit 1
    fi
    rm -f /tmp/mail-export-sshd-check.$$
    echo "  sshd -t: OK"
    eff="$("$SSHD_BIN" -T -C "user=$U,host=localhost,addr=127.0.0.1" 2>/dev/null || true)"
    if [ -n "$eff" ]; then
      echo "  effective settings for $U:"; grep -iE '^(chrootdirectory|forcecommand|allowtcpforwarding|permittty|passwordauthentication|authorizedkeysfile) ' <<<"$eff" | sed 's/^/    /'
      if grep -iE '^(allowusers|allowgroups) ' <<<"$eff" | grep -viq "\b$U\b"; then
        echo "  !! AllowUsers/AllowGroups is set globally and does not list $U: the login will be REFUSED. Add $U to it (see your hardening file in $SSHD_DIR)." >&2
      fi
    fi
  else
    echo "  (sshd binary not found: configuration NOT validated — run 'sudo sshd -t' yourself)"
  fi
else
  echo "  (dry run) would validate with: sshd -t"
fi
say "purge script and systemd units"
run install -D -m 0755 "$HERE/purge-mail-exports.sh" "$SBIN/purge-mail-exports"
run install -D -m 0644 "$HERE/mail-export-purge.service" "$UNITS/mail-export-purge.service"
run install -D -m 0644 "$HERE/mail-export-purge.timer" "$UNITS/mail-export-purge.timer"
if [ "$APPLY" = 1 ] && command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi
echo
echo "Next (by hand):"
echo "  1. sudo systemctl reload ssh        # applies the sshd drop-in (keep your current SSH session open and test a second one)"
echo "  2. sudo systemctl enable --now mail-export-purge.timer"
echo "  3. on the PC: pin the server key and run Export-Outlook.ps1 -DryRun (docs/mail-export.md)"
