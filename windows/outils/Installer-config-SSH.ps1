# Installe (ou met a jour) le raccourci SSH « aibeast » dans la configuration SSH de ce PC.
# Le bloc vient de « lab client » (sur la machine IA), copie a cote du dossier windows\ sous le nom
# windows\ssh_config_aibeast.txt. Utilisation : double-clic sur Installer-config-SSH.bat, ou
#   powershell -ExecutionPolicy Bypass -File .\Installer-config-SSH.ps1 [-Fichier CHEMIN]
#
# - Sauvegarde l'ancienne configuration (config.avant-AAAAMMJJ-HHMM) avant toute modification.
# - Remplace le bloc « Host aibeast » existant (jusqu'au « Host » ou « Match » suivant), ou l'ajoute a la fin.
# - Ne touche a aucun autre bloc. Ne lit ni ne copie aucune cle.
param(
    [string]$Fichier = (Join-Path $PSScriptRoot "..\ssh_config_aibeast.txt"),
    [string]$Config = (Join-Path $env:USERPROFILE ".ssh\config")
)
$ErrorActionPreference = "Stop"
function Fin($msg, $code) { Write-Host $msg; if ($Host.Name -eq "ConsoleHost") { Read-Host "Appuie sur Entree pour fermer" | Out-Null }; exit $code }

if (-not (Test-Path $Fichier)) { Fin "Fichier introuvable : $Fichier`nSur la machine IA : lab client, puis copie windows/ssh_config_aibeast.txt dans le dossier windows\ de ce PC." 1 }
$nouveau = @(Get-Content -Encoding UTF8 $Fichier | ForEach-Object { $_.TrimEnd("`r") })   # UTF8 : sinon PowerShell 5.1 abime les accents
if (-not ($nouveau | Where-Object { $_ -match '^\s*Host\s+aibeast\s*$' })) { Fin "Le fichier $Fichier ne contient pas de bloc 'Host aibeast'." 1 }
if (-not ($nouveau | Where-Object { $_ -match '^\s*HostName\s+\S' })) { Fin "Le fichier $Fichier ne contient pas de ligne HostName." 1 }

$dossier = Split-Path $Config
if (-not (Test-Path $dossier)) { New-Item -ItemType Directory -Path $dossier | Out-Null }
$ancien = @()
if (Test-Path $Config) {
    $sauvegarde = "$Config.avant-$(Get-Date -Format yyyyMMdd-HHmm)"
    Copy-Item $Config $sauvegarde
    Write-Host "Sauvegarde : $sauvegarde"
    $ancien = @(Get-Content -Encoding UTF8 $Config)
}

# Retirer l'ancien bloc « Host aibeast » (et les commentaires « # » qui le precedent immediatement)
$garde = New-Object System.Collections.Generic.List[string]
$dansBloc = $false; $retire = 0
foreach ($l in $ancien) {
    if ($l -match '^\s*Host\s+aibeast\s*$') {
        $dansBloc = $true; $retire++
        while ($garde.Count -gt 0 -and $garde[$garde.Count - 1] -match '^\s*#') { $garde.RemoveAt($garde.Count - 1) }
        continue
    }
    if ($dansBloc -and $l -match '^\s*(Host|Match)\s') { $dansBloc = $false }
    if (-not $dansBloc) { $garde.Add($l) }
}
while ($garde.Count -gt 0 -and $garde[$garde.Count - 1].Trim() -eq "") { $garde.RemoveAt($garde.Count - 1) }
if ($garde.Count -gt 0) { $garde.Add("") }
foreach ($l in $nouveau) { $garde.Add($l) }
# UTF-8 sans BOM : OpenSSH pour Windows lit mal un fichier avec BOM
[IO.File]::WriteAllLines($Config, $garde, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("Bloc 'Host aibeast' " + $(if ($retire -gt 0) { "remplace" } else { "ajoute" }) + " dans $Config.")
$fw = @($nouveau | Where-Object { $_ -match '^\s*LocalForward\s' }).Count
Write-Host "$fw tunnels definis. Ferme les tunnels ouverts (Fermer-tunnels-AiBeast) puis rouvre-les pour en profiter."
Write-Host "Test : ssh aibeast hostname"
Fin "OK." 0
