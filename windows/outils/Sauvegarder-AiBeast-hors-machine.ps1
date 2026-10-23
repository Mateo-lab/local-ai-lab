# Off-machine copy of AiBeast's backups: pulls the (encrypted) restic repository to this PC ("Sauvegarder" = back up).
# Usage: double-click Sauvegarder-AiBeast-hors-machine.bat (VPN connected, SSH key loaded).
#
# - Copies AiBeast's restic repository (location asked from AiBeast: `lab backup repo`) into <Destination>\restic-repo
#   (with scp, SSH only). Default <Destination>: aibeast-backup folder next to the windows\ folder.
# - Checks the number of files and the total size BEFORE replacing the previous copy.
# - Keeps ONE previous copy (restic-repo.precedent) in case the new one is bad.
# - Does NOT copy the repository's password (see docs/backups.md: without it, the copy is unreadable;
#   keep it in a password manager, not next to the copy).
# Folder and file names (restic-repo.nouveau, restic-repo.precedent, derniere-copie.txt) are kept for existing copies.
param(
    [string]$Destination = (Join-Path $PSScriptRoot "..\..\aibeast-backup"),
    [Alias('HostName')][string]$Hote = "aibeast",
    [Alias('RemoteRepo')][string]$DepotDistant = ""
)
$ErrorActionPreference = "Stop"
function Fin($msg, $code) { Write-Host $msg; Read-Host "Press Enter to close"; exit $code }

if (-not $DepotDistant) {
    $DepotDistant = (& ssh -o ClearAllForwardings=yes $Hote "~/.local/bin/lab backup repo" | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or -not $DepotDistant) { Fin "Could not ask AiBeast for the repository's location (VPN? SSH key? lab install done? see: ssh $Hote)." 1 }
    $DepotDistant = $DepotDistant.Trim()
}
Write-Host "Repository on AiBeast: $DepotDistant"
if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination | Out-Null }
$nouveau   = Join-Path $Destination "restic-repo.nouveau"
$courant   = Join-Path $Destination "restic-repo"
$precedent = Join-Path $Destination "restic-repo.precedent"
if (Test-Path $nouveau) { Remove-Item $nouveau -Recurse -Force }   # left over from an interrupted attempt (created by this script)
New-Item -ItemType Directory -Path $nouveau | Out-Null

# 1. Expected size on AiBeast (files only)
Write-Host "Reading the repository's state on AiBeast..."
$attendu = & ssh -o ClearAllForwardings=yes $Hote "find $DepotDistant -type f -printf '%s\n' | awk '{s+=`$1} END{print NR, s}'" | Select-Object -Last 1
if ($LASTEXITCODE -ne 0 -or -not $attendu) { Fin "Could not read the repository on AiBeast (VPN? SSH key? see: ssh $Hote)." 1 }
$nbAttendu, $octetsAttendu = $attendu.Trim().Split(" ")
Write-Host "  expected: $nbAttendu files, $octetsAttendu bytes"

# 2. Copy
Write-Host "Copying (can take a few minutes)..."
& scp -r -o ClearAllForwardings=yes "${Hote}:${DepotDistant}/*" $nouveau
if ($LASTEXITCODE -ne 0) { Fin "The copy failed. The old copy was not touched." 1 }

# 3. Check
$fichiers = Get-ChildItem -Path $nouveau -Recurse -File -Force
$nb = ($fichiers | Measure-Object).Count
$octets = ($fichiers | Measure-Object -Property Length -Sum).Sum
Write-Host "  copied  : $nb files, $octets bytes"
if ("$nb" -ne "$nbAttendu" -or "$octets" -ne "$octetsAttendu") {
    Fin "The numbers do not match (a backup may have been running during the copy: 03:30). Nothing was replaced; run again." 2
}

# 4. Replacement: a single previous copy kept
if (Test-Path $precedent) { Remove-Item $precedent -Recurse -Force }
if (Test-Path $courant)   { Rename-Item $courant "restic-repo.precedent" }
Rename-Item $nouveau "restic-repo"
(Get-Date).ToString("yyyy-MM-dd HH:mm") | Set-Content (Join-Path $Destination "derniere-copie.txt")
Fin "OK: copy checked in $courant ($nb files)." 0
