# Delivers a new version of the lab to AiBeast: sends ai-lab.tar.gz, checks it, backs up what is about to be
# replaced, extracts, checks. Usage: double-click Deployer-sur-AiBeast.bat ("Deployer" = deploy; VPN connected, SSH key loaded).
#
# - Sends the archive with scp to ~/ai-lab.tar.gz on AiBeast and compares its size with the PC's.
# - REFUSES to continue if a benchmark (lab bench) is running: replacing files during a measurement can skew it.
# - Backs up bench, docs, windows, scripts and lab (without bench/.venv or bench/results, never delivered) to ~/avant-YYYYMMDD-HHMM.tgz before extracting.
# - Extracts into ~/Documents (the archive adds and replaces files, it deletes none; the .env files are not in it).
# - Checks afterwards: compares every file of the archive with what is on disk (content, size, date; the
#   owner is ignored: tar cannot change it without being root).
param(
    [string]$Archive = (Join-Path $PSScriptRoot "..\..\ai-lab.tar.gz"),   # default: next to the windows\ folder
    [Alias('HostName')][string]$Hote = "aibeast"
)
$ErrorActionPreference = "Stop"
function Fin($msg, $code) { Write-Host $msg; Read-Host "Press Enter to close"; exit $code }

if (-not (Test-Path $Archive)) { Fin "Archive not found: $Archive" 1 }
$taille = (Get-Item $Archive).Length
Write-Host "Archive: $Archive ($taille bytes)"

Write-Host "Sending to AiBeast..."
& scp -o ClearAllForwardings=yes $Archive "${Hote}:ai-lab.tar.gz"
if ($LASTEXITCODE -ne 0) { Fin "Sending failed (VPN? SSH key? see: ssh $Hote). Nothing was changed on AiBeast." 1 }

# Script run on AiBeast (ASCII only: it goes through ssh's standard input)
$distant = @'
set -u
ARCH="$HOME/ai-lab.tar.gz"
DEST="$HOME/Documents"
got=$(stat -c %s "$ARCH" 2>/dev/null || echo 0)
if [ "$got" != "__TAILLE__" ]; then echo "Size received: $got instead of __TAILLE__"; exit 11; fi
echo "  size checked: $got bytes"
if pgrep -f "[l]abbench" >/dev/null || pgrep -f "[7]-bench.sh" >/dev/null; then
  echo "A benchmark is running (lab bench). Wait until it ends then run again. Nothing was extracted."; exit 10
fi
if ! tar tzf "$ARCH" >/dev/null 2>&1; then echo "Unreadable archive (corrupted?). Nothing was extracted."; exit 12; fi
cd "$DEST" || { echo "Folder $DEST not found"; exit 14; }
if [ -d ai-lab/.git ] && [ -n "$(git -C ai-lab status --porcelain 2>/dev/null)" ]; then echo "The ai-lab git repository has uncommitted changes (cd ~/Documents/ai-lab ; git status). Commit them first. Nothing was extracted."; exit 15; fi
L=""
for p in ai-lab/bench ai-lab/docs ai-lab/windows ai-lab/scripts ai-lab/lab; do [ -e "$p" ] && L="$L $p"; done
B="$HOME/avant-$(date +%Y%m%d-%H%M).tgz"
if [ -n "$L" ]; then
  tar czf "$B" --exclude=ai-lab/bench/.venv --exclude=ai-lab/bench/results --exclude=__pycache__ $L 2>/dev/null || { echo "Safety backup impossible. Nothing was extracted."; exit 13; }
  echo "  safety backup: $B ($(stat -c %s "$B") bytes)"
fi
tar xzf "$ARCH" -C "$DEST" 2>"$HOME/.deploiement-erreurs.txt"; rc=$?
diff_out=$(LANGUAGE=C LC_ALL=C tar dzf "$ARCH" -C "$DEST" 2>&1 | grep -v -i -E "Uid differs|Gid differs|UID est diff|GID est diff" | head -20)
if [ $rc -ne 0 ] || [ -n "$diff_out" ]; then
  echo "Extraction with problems (code $rc). First errors:"; head -10 "$HOME/.deploiement-erreurs.txt"
  echo "Files different from the archive:"; echo "$diff_out"
  exit 20
fi
echo "  extraction checked: every file of the archive is identical on disk"
if [ -d ai-lab/.git ]; then echo "  changes brought by the archive (git status):"; git -C ai-lab status --short | head -40; echo "  Check then commit (cd ~/Documents/ai-lab ; git add -A ; git commit), or undo (git checkout -- .)"; fi
exit 0
'@
$distant = ($distant -replace "`r", "").Replace("__TAILLE__", "$taille")

Write-Host "Checking and extracting on AiBeast..."
$distant | & ssh -o ClearAllForwardings=yes $Hote "bash -s"
$code = $LASTEXITCODE
switch ($code) {
    0  { Fin "OK: new version in place on AiBeast. To go back: the backup ~/avant-....tgz (see above)." 0 }
    10 { Fin "A benchmark is running: nothing was extracted. Run again when it is finished." 10 }
    11 { Fin "The size received does not match: nothing was extracted. Run again." 11 }
    12 { Fin "The archive is unreadable: nothing was extracted." 12 }
    13 { Fin "Safety backup impossible: nothing was extracted." 13 }
    15 { Fin "AiBeast's git repository has uncommitted changes: nothing was extracted. Commit or undo them, then run again." 15 }
    20 { Fin "Extraction done but with differences or errors (see above). Do not start a measurement before looking at them." 20 }
    default { Fin "Failed (code $code). See the messages above." $code }
}
