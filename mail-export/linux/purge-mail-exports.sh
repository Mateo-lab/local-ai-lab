#!/usr/bin/env bash
# Deletes exported mails older than N days from the drop folder (default /srv/mail-in/inbox).
#
#   purge-mail-exports.sh [--dir DIR] [--days N] [--apply]
#
# Without --apply it only LISTS what would be deleted (dry run). It never uses sudo, never follows symlinks out of DIR
# and refuses system folders. _export-status.json (the daily heartbeat) is never deleted: its age tells when the last
# export arrived. Stale ".tmp-*" files (interrupted uploads) are removed after one day.
set -euo pipefail
DIR=/srv/mail-in/inbox; DAYS=30; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:?--dir needs a value}"; shift 2 ;;
    --days) DAYS="${2:?--days needs a value}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -ge 1 ] || { echo "--days must be a whole number >= 1" >&2; exit 2; }
[ -d "$DIR" ] || { echo "Not a directory: $DIR" >&2; exit 2; }
REAL="$(readlink -f -- "$DIR")"
case "$REAL" in
  /|/bin|/boot|/dev|/etc|/home|/lib*|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/mnt|/media)
    echo "Refusing to purge a system folder: $REAL" >&2; exit 2 ;;
esac
# at least three path components (e.g. /srv/mail-in/inbox)
[ "$(awk -F/ '{n=0; for(i=1;i<=NF;i++) if($i!="") n++; print n}' <<<"$REAL")" -ge 3 ] \
  || { echo "Refusing: $REAL is too close to the root of the filesystem (need at least 3 components)." >&2; exit 2; }

mode="DRY RUN (nothing deleted; add --apply)"; [ "$APPLY" = 1 ] && mode="APPLY"
echo "Purge $REAL — files older than $DAYS day(s) — $mode"

FILES=(find "$REAL" -mindepth 1 -type f ! -name '_export-status.json' '(' '(' -name '.tmp-*' -mtime +0 ')' -o -mtime "+$((DAYS - 1))" ')')
# -mtime +N means "more than N full days": +(DAYS-1) rounds to "at least DAYS days old"
n=$("${FILES[@]}" -print | wc -l)
if [ "$APPLY" = 1 ]; then
  "${FILES[@]}" -print -delete
  find "$REAL" -mindepth 1 -type d -name '*.attachments' -empty -print -delete
  echo "Deleted $n file(s)."
else
  "${FILES[@]}" -print
  find "$REAL" -mindepth 1 -type d -name '*.attachments' -empty -print
  echo "$n file(s) would be deleted."
fi
