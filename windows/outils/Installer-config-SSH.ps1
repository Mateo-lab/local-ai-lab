# Installs (or updates) the "aibeast" SSH shortcut in this PC's SSH configuration ("Installer" = install).
# The block comes from "lab client" (on the AI machine), copied next to the windows\ folder as
# windows\ssh_config_aibeast.txt. Usage: double-click Installer-config-SSH.bat, or
#   powershell -ExecutionPolicy Bypass -File .\Installer-config-SSH.ps1 [-Path FILE]
#
# - Backs up the old configuration (config.avant-YYYYMMDD-HHMM) before any change.
# - Replaces the existing "Host aibeast" block (up to the next "Host" or "Match"), or adds it at the end.
# - Touches no other block. Neither reads nor copies any key.
param(
    [Alias('Path')][string]$Fichier = (Join-Path $PSScriptRoot "..\ssh_config_aibeast.txt"),
    [string]$Config = (Join-Path $env:USERPROFILE ".ssh\config")
)
$ErrorActionPreference = "Stop"
function Fin($msg, $code) { Write-Host $msg; if ($Host.Name -eq "ConsoleHost") { Read-Host "Press Enter to close" | Out-Null }; exit $code }

if (-not (Test-Path $Fichier)) { Fin "File not found: $Fichier`nOn the AI machine: lab client, then copy windows/ssh_config_aibeast.txt into this PC's windows\ folder." 1 }
$nouveau = @(Get-Content -Encoding UTF8 $Fichier | ForEach-Object { $_.TrimEnd("`r") })   # UTF8: otherwise PowerShell 5.1 damages non-ASCII characters
if (-not ($nouveau | Where-Object { $_ -match '^\s*Host\s+aibeast\s*$' })) { Fin "The file $Fichier contains no 'Host aibeast' block." 1 }
if (-not ($nouveau | Where-Object { $_ -match '^\s*HostName\s+\S' })) { Fin "The file $Fichier contains no HostName line." 1 }

$dossier = Split-Path $Config
if (-not (Test-Path $dossier)) { New-Item -ItemType Directory -Path $dossier | Out-Null }
$ancien = @()
if (Test-Path $Config) {
    $sauvegarde = "$Config.avant-$(Get-Date -Format yyyyMMdd-HHmm)"
    Copy-Item $Config $sauvegarde
    Write-Host "Backup: $sauvegarde"
    $ancien = @(Get-Content -Encoding UTF8 $Config)
}

# Remove the old "Host aibeast" block (and the "#" comments right before it)
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
# UTF-8 without BOM: OpenSSH for Windows misreads a file with a BOM
[IO.File]::WriteAllLines($Config, $garde, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("Block 'Host aibeast' " + $(if ($retire -gt 0) { "replaced" } else { "added" }) + " in $Config.")
$fw = @($nouveau | Where-Object { $_ -match '^\s*LocalForward\s' }).Count
Write-Host "$fw tunnels defined. Close the open tunnels (Fermer-tunnels-AiBeast) then reopen them to use them."
Write-Host "Test: ssh aibeast hostname"
Fin "OK." 0
