# Approves a .bat/.cmd/.py script so that the agent can run it as administrator ("Approuver" = approve; see Installer-admin-hermes.ps1).
# To run AS ADMINISTRATOR on the test machine:
#   powershell -ExecutionPolicy Bypass -File .\Approuver-script-hermes.ps1 -Script C:\Users\hermes\work\project\test.bat
#   powershell -ExecutionPolicy Bypass -File .\Approuver-script-hermes.ps1 -List
#   powershell -ExecutionPolicy Bypass -File .\Approuver-script-hermes.ps1 -Remove test.bat
#   powershell -ExecutionPolicy Bypass -File .\Approuver-script-hermes.ps1 -Log            latest runs
# (The former French parameter names -Fichier, -Lister, -Retirer and -Journal still work.)
# The script is SHOWN in full: read it. What is approved runs with SYSTEM rights.
# Rule: an approved script must only call files in the approved scripts folder (%~dp0 for .bat, the script's own
# folder for .py), never a file the agent can change (its profile, C:\Users\hermes\...), otherwise the agent could
# change what runs. A .py may import the standard library, packages installed for all users (pip as administrator)
# and modules placed next to it, which must therefore be approved too.
param([Alias('Script')][string]$Fichier, [Alias('Remove')][string]$Retirer, [Alias('List')][switch]$Lister, [Alias('Log')][switch]$Journal)
$ErrorActionPreference = "Stop"
$Base = "C:\ProgramData\hermes-admin"; $Dest = "$Base\approuves"
$moi = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $moi.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host "Run this script AS ADMINISTRATOR." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Dest)) { Write-Host "Run Installer-admin-hermes.ps1 first." -ForegroundColor Red; exit 1 }

if ($Lister) {
    Get-ChildItem $Dest -File | ForEach-Object { "{0,-40} {1:yyyy-MM-dd HH:mm}  {2}" -f $_.Name, $_.LastWriteTime, (Get-FileHash $_.FullName).Hash.Substring(0, 16) }
    exit 0
}
if ($Journal) { Get-Content "$Base\resultats\journal.log" -Tail 30 -ErrorAction SilentlyContinue; exit 0 }
if ($Retirer) {
    $c = Join-Path $Dest (Split-Path $Retirer -Leaf)
    if (Test-Path $c) { Remove-Item $c -Force; Add-Content "$Base\approbations.log" ("{0:yyyy-MM-dd HH:mm}  REMOVED  {1}" -f (Get-Date), (Split-Path $c -Leaf)); Write-Host "Removed: $c" }
    else { Write-Host "Not found: $c" }
    exit 0
}
if (-not $Fichier -or -not (Test-Path -LiteralPath $Fichier -PathType Leaf)) { Write-Host "Give -Script PATH (or -List, -Remove NAME, -Log)."; exit 1 }
$nom = Split-Path $Fichier -Leaf
if ($nom -notmatch '^[A-Za-z0-9_-]{1,64}\.(bat|cmd|py)$') { Write-Host "Name refused: $nom (letters, digits, _ and -; extension .bat, .cmd or .py)." -ForegroundColor Red; exit 1 }

$lignes = @(Get-Content -LiteralPath $Fichier)
$hash = (Get-FileHash -LiteralPath $Fichier).Hash
Write-Host "===== $Fichier ($($lignes.Count) lines, SHA256 $hash) =====" -ForegroundColor Cyan
for ($i = 0; $i -lt $lignes.Count; $i++) { Write-Host ("{0,4}  {1}" -f ($i + 1), $lignes[$i]) }
Write-Host "===== end of script =====" -ForegroundColor Cyan

$suspect = 'Users\\|%USERPROFILE%|%HOMEPATH%|%TEMP%|%TMP%|%APPDATA%|\\work\\|netsh|firewall|Set-NetFirewall|NetFirewallRule|sshd|ssh\\|net\s+user|net\s+localgroup|Add-LocalGroupMember|icacls|takeown|schtasks|Register-ScheduledTask|sc(\.exe)?\s+(create|config)|New-Service|reg(\.exe)?\s+(add|delete|import)|Set-ItemProperty|curl|wget|Invoke-WebRequest|Invoke-RestMethod|bitsadmin|certutil|DownloadString|DownloadFile|powershell.*-enc|EncodedCommand|hermes-admin'
# Python: commands, network, registry, native calls, dynamic code (a warning to read, not a ban)
if ($nom -like '*.py') { $suspect += '|subprocess|os\.system|os\.popen|os\.exec|os\.spawn|urllib|requests|http\.client|socket|winreg|ctypes|win32api|win32security|win32service|exec\(|eval\(|__import__|importlib|shutil\.rmtree|sys\.path' }
$alertes = 0
for ($i = 0; $i -lt $lignes.Count; $i++) {
    if ($lignes[$i] -match $suspect) { $alertes++; Write-Host ("WARNING line {0}: {1}" -f ($i + 1), $lignes[$i].Trim()) -ForegroundColor Yellow }
}
if ($alertes -gt 0) { Write-Host "$alertes line(s) to examine: firewall, SSH, accounts, rights, tasks, services, registry, download, or a file the agent can change." -ForegroundColor Yellow }
$r = Read-Host "Approve this script, which will run with SYSTEM rights? Type exactly 'yes'"
if ($r -ne "yes" -and $r -ne "oui") { Write-Host "Not approved."; exit 1 }
$c = Join-Path $Dest $nom
Copy-Item -LiteralPath $Fichier -Destination $c -Force
if ((Get-FileHash $c).Hash -ne $hash) { Remove-Item $c -Force; Write-Host "The file changed during approval: refused." -ForegroundColor Red; exit 1 }
Add-Content "$Base\approbations.log" ("{0:yyyy-MM-dd HH:mm}  APPROVED  {1}  SHA256 {2}  from {3}" -f (Get-Date), $nom, $hash, $Fichier)
Write-Host "Approved: $c. The agent can run it with lancer.ps1 $nom [arguments]." -ForegroundColor Green
