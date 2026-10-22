# Approuve un script .bat/.cmd pour que l'agent puisse le lancer en administrateur (voir Installer-admin-hermes.ps1).
# A lancer EN ADMINISTRATEUR sur la machine de test :
#   powershell -ExecutionPolicy Bypass -File .\Approuver-script-hermes.ps1 -Fichier C:\Users\hermes\work\projet\test.bat
#   powershell -ExecutionPolicy Bypass -File .\Approuver-script-hermes.ps1 -Lister
#   powershell -ExecutionPolicy Bypass -File .\Approuver-script-hermes.ps1 -Retirer test.bat
#   powershell -ExecutionPolicy Bypass -File .\Approuver-script-hermes.ps1 -Journal          dernieres executions
# Le script est AFFICHE en entier : lis-le. Ce qui est approuve s'execute avec les droits SYSTEM.
# Regle : un script approuve ne doit appeler que des fichiers du dossier des scripts approuves (%~dp0), jamais un
# fichier que l'agent peut modifier (son profil, C:\Users\hermes\...), sinon l'agent pourrait changer ce qui s'execute.
param([string]$Fichier, [string]$Retirer, [switch]$Lister, [switch]$Journal)
$ErrorActionPreference = "Stop"
$Base = "C:\ProgramData\hermes-admin"; $Dest = "$Base\approuves"
$moi = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $moi.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host "Lance ce script EN ADMINISTRATEUR." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Dest)) { Write-Host "Lance d'abord Installer-admin-hermes.ps1." -ForegroundColor Red; exit 1 }

if ($Lister) {
    Get-ChildItem $Dest -File | ForEach-Object { "{0,-40} {1:yyyy-MM-dd HH:mm}  {2}" -f $_.Name, $_.LastWriteTime, (Get-FileHash $_.FullName).Hash.Substring(0, 16) }
    exit 0
}
if ($Journal) { Get-Content "$Base\resultats\journal.log" -Tail 30 -ErrorAction SilentlyContinue; exit 0 }
if ($Retirer) {
    $c = Join-Path $Dest (Split-Path $Retirer -Leaf)
    if (Test-Path $c) { Remove-Item $c -Force; Add-Content "$Base\approbations.log" ("{0:yyyy-MM-dd HH:mm}  RETIRE  {1}" -f (Get-Date), (Split-Path $c -Leaf)); Write-Host "Retire : $c" }
    else { Write-Host "Introuvable : $c" }
    exit 0
}
if (-not $Fichier -or -not (Test-Path -LiteralPath $Fichier -PathType Leaf)) { Write-Host "Indique -Fichier CHEMIN (ou -Lister, -Retirer NOM, -Journal)."; exit 1 }
$nom = Split-Path $Fichier -Leaf
if ($nom -notmatch '^[A-Za-z0-9_-]{1,64}\.(bat|cmd)$') { Write-Host "Nom refuse : $nom (lettres, chiffres, _ et - ; extension .bat ou .cmd)." -ForegroundColor Red; exit 1 }

$lignes = @(Get-Content -LiteralPath $Fichier)
$hash = (Get-FileHash -LiteralPath $Fichier).Hash
Write-Host "===== $Fichier ($($lignes.Count) lignes, SHA256 $hash) =====" -ForegroundColor Cyan
for ($i = 0; $i -lt $lignes.Count; $i++) { Write-Host ("{0,4}  {1}" -f ($i + 1), $lignes[$i]) }
Write-Host "===== fin du script =====" -ForegroundColor Cyan

$suspect = 'Users\\|%USERPROFILE%|%HOMEPATH%|%TEMP%|%TMP%|%APPDATA%|\\work\\|netsh|firewall|Set-NetFirewall|NetFirewallRule|sshd|ssh\\|net\s+user|net\s+localgroup|Add-LocalGroupMember|icacls|takeown|schtasks|Register-ScheduledTask|sc(\.exe)?\s+(create|config)|New-Service|reg(\.exe)?\s+(add|delete|import)|Set-ItemProperty|curl|wget|Invoke-WebRequest|Invoke-RestMethod|bitsadmin|certutil|DownloadString|DownloadFile|powershell.*-enc|EncodedCommand|hermes-admin'
$alertes = 0
for ($i = 0; $i -lt $lignes.Count; $i++) {
    if ($lignes[$i] -match $suspect) { $alertes++; Write-Host ("ATTENTION ligne {0} : {1}" -f ($i + 1), $lignes[$i].Trim()) -ForegroundColor Yellow }
}
if ($alertes -gt 0) { Write-Host "$alertes ligne(s) a examiner : pare-feu, SSH, comptes, droits, taches, services, registre, telechargement, ou fichier modifiable par l'agent." -ForegroundColor Yellow }
$r = Read-Host "Approuver ce script, qui s'executera avec les droits SYSTEM ? Tape exactement 'oui'"
if ($r -ne "oui") { Write-Host "Non approuve."; exit 1 }
$c = Join-Path $Dest $nom
Copy-Item -LiteralPath $Fichier -Destination $c -Force
if ((Get-FileHash $c).Hash -ne $hash) { Remove-Item $c -Force; Write-Host "Le fichier a change pendant l'approbation : refuse." -ForegroundColor Red; exit 1 }
Add-Content "$Base\approbations.log" ("{0:yyyy-MM-dd HH:mm}  APPROUVE  {1}  SHA256 {2}  depuis {3}" -f (Get-Date), $nom, $hash, $Fichier)
Write-Host "Approuve : $c. L'agent peut le lancer avec lancer.ps1 $nom [arguments]." -ForegroundColor Green
