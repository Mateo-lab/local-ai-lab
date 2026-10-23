# Copie hors machine des sauvegardes d'AiBeast : récupère le dépôt restic (chiffré) sur ce PC.
# Utilisation : double-clic sur Sauvegarder-AiBeast-hors-machine.bat (VPN connecté, clé SSH chargée).
#
# - Copie le dépôt restic d'AiBeast (emplacement demandé à AiBeast : `lab backup repo`) dans <Destination>\restic-repo
#   (via scp, SSH uniquement). <Destination> par défaut : dossier aibeast-backup à côté du dossier windows\.
# - Vérifie le nombre de fichiers et la taille totale AVANT de remplacer la copie précédente.
# - Garde UNE copie précédente (restic-repo.precedent) au cas où la nouvelle serait mauvaise.
# - Ne copie PAS le mot de passe du dépôt (voir docs/backups.md : sans lui, la copie est illisible ;
#   garde-le dans un gestionnaire de mots de passe, pas à côté de la copie).
param(
    [string]$Destination = (Join-Path $PSScriptRoot "..\..\aibeast-backup"),
    [string]$Hote = "aibeast",
    [string]$DepotDistant = ""
)
$ErrorActionPreference = "Stop"
function Fin($msg, $code) { Write-Host $msg; Read-Host "Appuie sur Entrée pour fermer"; exit $code }

if (-not $DepotDistant) {
    $DepotDistant = (& ssh -o ClearAllForwardings=yes $Hote "~/.local/bin/lab backup repo" | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or -not $DepotDistant) { Fin "Impossible de demander l'emplacement du dépôt à AiBeast (VPN ? clé SSH ? lab install fait ? voir : ssh $Hote)." 1 }
    $DepotDistant = $DepotDistant.Trim()
}
Write-Host "Dépôt sur AiBeast : $DepotDistant"
if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination | Out-Null }
$nouveau   = Join-Path $Destination "restic-repo.nouveau"
$courant   = Join-Path $Destination "restic-repo"
$precedent = Join-Path $Destination "restic-repo.precedent"
if (Test-Path $nouveau) { Remove-Item $nouveau -Recurse -Force }   # reste d'un essai interrompu (créé par ce script)
New-Item -ItemType Directory -Path $nouveau | Out-Null

# 1. Taille attendue côté AiBeast (fichiers seulement)
Write-Host "Lecture de l'état du dépôt sur AiBeast..."
$attendu = & ssh -o ClearAllForwardings=yes $Hote "find $DepotDistant -type f -printf '%s\n' | awk '{s+=`$1} END{print NR, s}'" | Select-Object -Last 1
if ($LASTEXITCODE -ne 0 -or -not $attendu) { Fin "Impossible de lire le dépôt sur AiBeast (VPN ? clé SSH ? voir : ssh $Hote)." 1 }
$nbAttendu, $octetsAttendu = $attendu.Trim().Split(" ")
Write-Host "  attendu : $nbAttendu fichiers, $octetsAttendu octets"

# 2. Copie
Write-Host "Copie en cours (peut durer quelques minutes)..."
& scp -r -o ClearAllForwardings=yes "${Hote}:${DepotDistant}/*" $nouveau
if ($LASTEXITCODE -ne 0) { Fin "La copie a échoué. L'ancienne copie n'a pas été touchée." 1 }

# 3. Vérification
$fichiers = Get-ChildItem -Path $nouveau -Recurse -File -Force
$nb = ($fichiers | Measure-Object).Count
$octets = ($fichiers | Measure-Object -Property Length -Sum).Sum
Write-Host "  copié   : $nb fichiers, $octets octets"
if ("$nb" -ne "$nbAttendu" -or "$octets" -ne "$octetsAttendu") {
    Fin "Les chiffres ne correspondent pas (une sauvegarde tournait peut-être pendant la copie : 03:30). Rien n'a été remplacé ; relance." 2
}

# 4. Remplacement : une seule copie précédente conservée
if (Test-Path $precedent) { Remove-Item $precedent -Recurse -Force }
if (Test-Path $courant)   { Rename-Item $courant "restic-repo.precedent" }
Rename-Item $nouveau "restic-repo"
(Get-Date).ToString("yyyy-MM-dd HH:mm") | Set-Content (Join-Path $Destination "derniere-copie.txt")
Fin "OK : copie vérifiée dans $courant ($nb fichiers)." 0
