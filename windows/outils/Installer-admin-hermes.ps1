# Lets the agent (hermes account) run AS ADMINISTRATOR the .bat/.cmd scripts that YOU approved,
# without giving it administrator rights. To run AS ADMINISTRATOR on the test machine:
#
#   powershell -ExecutionPolicy Bypass -File .\Installer-admin-hermes.ps1               installs (account: hermes)
#   powershell -ExecutionPolicy Bypass -File .\Installer-admin-hermes.ps1 -Uninstall    removes everything
# (The former French parameter names -Utilisateur and -Desinstaller still work.)
#
# What is created (details: docs/hermes-ssh.md, "Administrator scripts" section). Folder names are French
# ("outils" = tools, "approuves" = approved, "demandes" = requests, "resultats" = results) and kept as is:
#   C:\ProgramData\hermes-admin\outils\     executer.ps1 (run by the task) and lancer.ps1 (used by the agent)
#   C:\ProgramData\hermes-admin\approuves\  approved scripts (Approuver-script-hermes.ps1): the agent can read them, NOT change them
#   C:\ProgramData\hermes-admin\demandes\   the agent drops a request there (script name + arguments): the only folder it writes to
#   C:\ProgramData\hermes-admin\resultats\  output and exit code of each run (read-only for the agent)
#   Scheduled task \local-ai-lab\Hermes-admin: SYSTEM account; the agent can TRIGGER it, not change it.
# The agent never becomes an administrator: it can touch neither the firewall nor sshd_config, nor run as
# administrator anything other than the approved scripts, with filtered arguments (letters, digits, _ . : = / + -).
param(
    [Alias('User')][string]$Utilisateur = "hermes",
    [Alias('Uninstall')][switch]$Desinstaller
)
$ErrorActionPreference = "Stop"
$Base = "C:\ProgramData\hermes-admin"
$Tache = "Hermes-admin"; $Dossier = "\local-ai-lab"

$moi = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $moi.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Run this script AS ADMINISTRATOR." -ForegroundColor Red; exit 1
}
$svc = New-Object -ComObject Schedule.Service; $svc.Connect()

if ($Desinstaller) {
    try { $svc.GetFolder($Dossier).DeleteTask($Tache, 0) } catch { }
    if (Test-Path $Base) { Remove-Item $Base -Recurse -Force }
    Write-Host "Task and folder $Base removed."; exit 0
}

$compte = Get-LocalUser -Name $Utilisateur -ErrorAction SilentlyContinue
if (-not $compte) { Write-Host "Local account '$Utilisateur' not found." -ForegroundColor Red; exit 1 }
$sid = $compte.SID.Value
$admins = (New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544")).Translate([Security.Principal.NTAccount]).Value
if ((Get-LocalGroupMember -SID S-1-5-32-544 | Where-Object { $_.SID.Value -eq $sid })) {
    Write-Host "WARNING: $Utilisateur is an administrator. Remove it from the $admins group: this setup only makes sense for a standard account." -ForegroundColor Yellow
}

# 1. Folders and rights (universal SIDs: valid whatever the language of Windows)
foreach ($d in "", "\outils", "\approuves", "\demandes", "\resultats") { New-Item -ItemType Directory -Force -Path "$Base$d" | Out-Null }
icacls $Base /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*$($sid):(OI)(CI)RX" | Out-Null
icacls "$Base\demandes" /grant "*$($sid):(OI)(CI)M" | Out-Null
foreach ($d in "", "\outils", "\approuves", "\demandes", "\resultats") { icacls "$Base$d" /setowner "*S-1-5-32-544" /T /C | Out-Null }

# 2. Script run by the task (SYSTEM account)
@'
# Runs the requests dropped by the agent, one by one. Started by the task \local-ai-lab\Hermes-admin (SYSTEM).
$Base = "C:\ProgramData\hermes-admin"
$journal = "$Base\resultats\journal.log"
function J([string]$m) { Add-Content -Path $journal -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) }
for ($tour = 0; $tour -lt 100; $tour++) {
    $d = Get-ChildItem "$Base\demandes" -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -First 1
    if (-not $d) { break }
    $id = $d.BaseName; $req = $null
    try { $req = Get-Content -LiteralPath $d.FullName -Raw | ConvertFrom-Json } catch { }
    Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
    if ($id -notmatch '^[0-9]{17}$') { J "refused: invalid identifier '$id'"; continue }
    $log = "$Base\resultats\$id.log"; $fin = "$Base\resultats\$id.code"
    $nom = if ($req) { [string]$req.script } else { "" }
    $arg = @(); if ($req -and $req.args) { $arg = @($req.args | ForEach-Object { [string]$_ }) }
    $raison = $null
    if ($nom -notmatch '^[A-Za-z0-9_-]{1,64}\.(bat|cmd)$') { $raison = "invalid script name '$nom'" }
    elseif (-not (Test-Path -LiteralPath (Join-Path "$Base\approuves" $nom) -PathType Leaf)) { $raison = "script not approved '$nom'" }
    elseif ($arg.Count -gt 10) { $raison = "too many arguments" }
    else { foreach ($a in $arg) { if ($a -notmatch '^[A-Za-z0-9_.:=/+-]{1,128}$') { $raison = "argument refused '$a'" } } }
    if ($raison) { "REFUSED: $raison" | Set-Content $log; "-1" | Set-Content $fin; J "refused ($id): $raison"; continue }
    $chemin = Join-Path "$Base\approuves" $nom
    J "start ($id): $nom $($arg -join ' ')"
    $p = Start-Process -FilePath "$env:WINDIR\System32\cmd.exe" -ArgumentList ('/d /c ""' + $chemin + '" ' + ($arg -join ' ') + ' > "' + $log + '" 2>&1"') `
         -WorkingDirectory "$Base\approuves" -WindowStyle Hidden -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit(3600 * 1000)) {
        & "$env:WINDIR\System32\taskkill.exe" /T /F /PID $p.Id | Out-Null
        Add-Content $log "STOPPED: maximum duration (1 h) exceeded"; $code = -2
    } else { $code = $p.ExitCode }
    "$code" | Set-Content $fin
    J "end ($id): $nom, code $code"
}
'@ | Set-Content -Path "$Base\outils\executer.ps1" -Encoding UTF8

# 3. The agent's command (hermes account): drops the request, triggers the task, waits and shows the result
@'
# Usage (by the agent, over SSH):
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\hermes-admin\outils\lancer.ps1             lists the approved scripts
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\hermes-admin\outils\lancer.ps1 NAME.bat [ARG...]
# Arguments: letters, digits and _ . : = / + - only (10 at most). Exit code = the script's
# (-1 refused, -2 time exceeded, 124 no result after waiting).
$Base = "C:\ProgramData\hermes-admin"
if ($args.Count -eq 0) {
    Write-Output "Approved scripts (can run as administrator):"
    Get-ChildItem "$Base\approuves" -File | ForEach-Object { "  {0}  (approved on {1:yyyy-MM-dd HH:mm})" -f $_.Name, $_.LastWriteTime }
    exit 0
}
$nom = [string]$args[0]; $arg = @(); if ($args.Count -gt 1) { $arg = @($args[1..($args.Count - 1)] | ForEach-Object { [string]$_ }) }
if ($nom -notmatch '^[A-Za-z0-9_-]{1,64}\.(bat|cmd)$') { Write-Output "Invalid script name: $nom"; exit 2 }
if (-not (Test-Path (Join-Path "$Base\approuves" $nom))) { Write-Output "Script not approved: $nom. Ask the human to approve it (Approuver-script-hermes.ps1)."; exit 3 }
foreach ($a in $arg) { if ($a -notmatch '^[A-Za-z0-9_.:=/+-]{1,128}$') { Write-Output "Argument refused: $a"; exit 2 } }
$id = (Get-Date).ToString("yyyyMMddHHmmssfff")
$dem = "$Base\demandes\$id.json"
@{ script = $nom; args = $arg } | ConvertTo-Json -Compress | Set-Content -Path $dem -Encoding ascii
$svc = New-Object -ComObject Schedule.Service; $svc.Connect()
$tache = $svc.GetFolder("\local-ai-lab").GetTask("Hermes-admin")
$fin = "$Base\resultats\$id.code"; $limite = (Get-Date).AddMinutes(65)
$null = $tache.Run($null)
while (-not (Test-Path $fin) -and (Get-Date) -lt $limite) {
    Start-Sleep -Seconds 3
    if ((Test-Path $dem) -and $tache.State -ne 4) { $null = $tache.Run($null) }   # 4 = running; otherwise trigger again
}
if (-not (Test-Path $fin)) { Write-Output "No result after 65 min (request $id)."; exit 124 }
Get-Content "$Base\resultats\$id.log" -ErrorAction SilentlyContinue
$code = [int](Get-Content $fin | Select-Object -First 1)
Write-Output "--- exit code: $code"
exit $code
'@ | Set-Content -Path "$Base\outils\lancer.ps1" -Encoding UTF8

# 4. Scheduled task (SYSTEM) the agent can trigger (read + execute rights on the task only)
try { $dossierTache = $svc.GetFolder($Dossier) } catch { $dossierTache = $svc.GetFolder("\").CreateFolder($Dossier) }
$def = $svc.NewTask(0)
$def.RegistrationInfo.Description = "local-ai-lab: runs as administrator the approved scripts requested by $Utilisateur"
$def.Settings.MultipleInstances = 2          # one at a time (waiting requests are handled in the loop)
$def.Settings.ExecutionTimeLimit = "PT2H"
$def.Settings.DisallowStartIfOnBatteries = $false
$def.Settings.StopIfGoingOnBatteries = $false
$def.Principal.RunLevel = 1                  # highest privileges
$action = $def.Actions.Create(0)
$action.Path = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$action.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Base\outils\executer.ps1`""
$sddl = "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;$sid)"
$null = $dossierTache.RegisterTaskDefinition($Tache, $def, 6, "SYSTEM", $null, 5, $sddl)
Write-Host "Installed: folder $Base, task $Dossier\$Tache (SYSTEM), can be triggered by $Utilisateur."
Write-Host "Approve a script: powershell -ExecutionPolicy Bypass -File .\Approuver-script-hermes.ps1 -Script C:\Users\$Utilisateur\work\...\test.bat"
Write-Host "Test (from the AI machine): ssh -F /opt/data/ssh/config NAME 'powershell -NoProfile -ExecutionPolicy Bypass -File $Base\outils\lancer.ps1'"
