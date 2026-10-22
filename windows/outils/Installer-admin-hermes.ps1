# Permet a l'agent (compte hermes) de lancer EN ADMINISTRATEUR des scripts .bat/.cmd que TU as approuves,
# sans lui donner les droits d'administrateur. A lancer EN ADMINISTRATEUR sur la machine de test :
#
#   powershell -ExecutionPolicy Bypass -File .\Installer-admin-hermes.ps1                 installe (compte : hermes)
#   powershell -ExecutionPolicy Bypass -File .\Installer-admin-hermes.ps1 -Desinstaller   retire tout
#
# Ce qui est cree (detail : docs/hermes-ssh.md, section « Scripts en administrateur ») :
#   C:\ProgramData\hermes-admin\outils\     executer.ps1 (lance par la tache) et lancer.ps1 (utilise par l'agent)
#   C:\ProgramData\hermes-admin\approuves\  scripts approuves (Approuver-script-hermes.ps1) : l'agent peut les lire, PAS les modifier
#   C:\ProgramData\hermes-admin\demandes\   l'agent y depose une demande (nom du script + arguments) : seul dossier ou il ecrit
#   C:\ProgramData\hermes-admin\resultats\  sortie et code de retour de chaque execution (lecture seule pour l'agent)
#   Tache planifiee \local-ai-lab\Hermes-admin : compte SYSTEM ; l'agent peut la DECLENCHER, pas la modifier.
# L'agent ne devient jamais administrateur : il ne peut ni toucher au pare-feu ni a sshd_config, ni executer en
# administrateur autre chose que les scripts approuves, avec des arguments filtres (lettres, chiffres, _ . : = / + -).
param(
    [string]$Utilisateur = "hermes",
    [switch]$Desinstaller
)
$ErrorActionPreference = "Stop"
$Base = "C:\ProgramData\hermes-admin"
$Tache = "Hermes-admin"; $Dossier = "\local-ai-lab"

$moi = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $moi.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Lance ce script EN ADMINISTRATEUR." -ForegroundColor Red; exit 1
}
$svc = New-Object -ComObject Schedule.Service; $svc.Connect()

if ($Desinstaller) {
    try { $svc.GetFolder($Dossier).DeleteTask($Tache, 0) } catch { }
    if (Test-Path $Base) { Remove-Item $Base -Recurse -Force }
    Write-Host "Tache et dossier $Base retires."; exit 0
}

$compte = Get-LocalUser -Name $Utilisateur -ErrorAction SilentlyContinue
if (-not $compte) { Write-Host "Compte local '$Utilisateur' introuvable." -ForegroundColor Red; exit 1 }
$sid = $compte.SID.Value
$admins = (New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544")).Translate([Security.Principal.NTAccount]).Value
if ((Get-LocalGroupMember -SID S-1-5-32-544 | Where-Object { $_.SID.Value -eq $sid })) {
    Write-Host "ATTENTION : $Utilisateur est administrateur. Retire-le du groupe $admins : ce dispositif n'a de sens que pour un compte standard." -ForegroundColor Yellow
}

# 1. Dossiers et droits (SID universels : valable en francais comme en anglais)
foreach ($d in "", "\outils", "\approuves", "\demandes", "\resultats") { New-Item -ItemType Directory -Force -Path "$Base$d" | Out-Null }
icacls $Base /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*$($sid):(OI)(CI)RX" | Out-Null
icacls "$Base\demandes" /grant "*$($sid):(OI)(CI)M" | Out-Null
foreach ($d in "", "\outils", "\approuves", "\demandes", "\resultats") { icacls "$Base$d" /setowner "*S-1-5-32-544" /T /C | Out-Null }

# 2. Script lance par la tache (compte SYSTEM)
@'
# Execute les demandes deposees par l'agent, une par une. Lance par la tache \local-ai-lab\Hermes-admin (SYSTEM).
$Base = "C:\ProgramData\hermes-admin"
$journal = "$Base\resultats\journal.log"
function J([string]$m) { Add-Content -Path $journal -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) }
for ($tour = 0; $tour -lt 100; $tour++) {
    $d = Get-ChildItem "$Base\demandes" -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -First 1
    if (-not $d) { break }
    $id = $d.BaseName; $req = $null
    try { $req = Get-Content -LiteralPath $d.FullName -Raw | ConvertFrom-Json } catch { }
    Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
    if ($id -notmatch '^[0-9]{17}$') { J "refus : identifiant invalide '$id'"; continue }
    $log = "$Base\resultats\$id.log"; $fin = "$Base\resultats\$id.code"
    $nom = if ($req) { [string]$req.script } else { "" }
    $arg = @(); if ($req -and $req.args) { $arg = @($req.args | ForEach-Object { [string]$_ }) }
    $raison = $null
    if ($nom -notmatch '^[A-Za-z0-9_-]{1,64}\.(bat|cmd)$') { $raison = "nom de script invalide '$nom'" }
    elseif (-not (Test-Path -LiteralPath (Join-Path "$Base\approuves" $nom) -PathType Leaf)) { $raison = "script non approuve '$nom'" }
    elseif ($arg.Count -gt 10) { $raison = "trop d'arguments" }
    else { foreach ($a in $arg) { if ($a -notmatch '^[A-Za-z0-9_.:=/+-]{1,128}$') { $raison = "argument refuse '$a'" } } }
    if ($raison) { "REFUS : $raison" | Set-Content $log; "-1" | Set-Content $fin; J "refus ($id) : $raison"; continue }
    $chemin = Join-Path "$Base\approuves" $nom
    J "debut ($id) : $nom $($arg -join ' ')"
    $p = Start-Process -FilePath "$env:WINDIR\System32\cmd.exe" -ArgumentList ('/d /c ""' + $chemin + '" ' + ($arg -join ' ') + ' > "' + $log + '" 2>&1"') `
         -WorkingDirectory "$Base\approuves" -WindowStyle Hidden -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit(3600 * 1000)) {
        & "$env:WINDIR\System32\taskkill.exe" /T /F /PID $p.Id | Out-Null
        Add-Content $log "ARRET : duree maximale (1 h) depassee"; $code = -2
    } else { $code = $p.ExitCode }
    "$code" | Set-Content $fin
    J "fin ($id) : $nom, code $code"
}
'@ | Set-Content -Path "$Base\outils\executer.ps1" -Encoding UTF8

# 3. Commande de l'agent (compte hermes) : depose la demande, declenche la tache, attend et affiche le resultat
@'
# Utilisation (par l'agent, depuis SSH) :
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\hermes-admin\outils\lancer.ps1             liste les scripts approuves
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\hermes-admin\outils\lancer.ps1 NOM.bat [ARG...]
# Arguments : lettres, chiffres et _ . : = / + - seulement (10 au plus). Code de sortie = celui du script
# (-1 refus, -2 duree depassee, 124 pas de resultat apres l'attente).
$Base = "C:\ProgramData\hermes-admin"
if ($args.Count -eq 0) {
    Write-Output "Scripts approuves (lancables en administrateur) :"
    Get-ChildItem "$Base\approuves" -File | ForEach-Object { "  {0}  (approuve le {1:yyyy-MM-dd HH:mm})" -f $_.Name, $_.LastWriteTime }
    exit 0
}
$nom = [string]$args[0]; $arg = @(); if ($args.Count -gt 1) { $arg = @($args[1..($args.Count - 1)] | ForEach-Object { [string]$_ }) }
if ($nom -notmatch '^[A-Za-z0-9_-]{1,64}\.(bat|cmd)$') { Write-Output "Nom de script invalide : $nom"; exit 2 }
if (-not (Test-Path (Join-Path "$Base\approuves" $nom))) { Write-Output "Script non approuve : $nom. Demande a l'humain de l'approuver (Approuver-script-hermes.ps1)."; exit 3 }
foreach ($a in $arg) { if ($a -notmatch '^[A-Za-z0-9_.:=/+-]{1,128}$') { Write-Output "Argument refuse : $a"; exit 2 } }
$id = (Get-Date).ToString("yyyyMMddHHmmssfff")
$dem = "$Base\demandes\$id.json"
@{ script = $nom; args = $arg } | ConvertTo-Json -Compress | Set-Content -Path $dem -Encoding ascii
$svc = New-Object -ComObject Schedule.Service; $svc.Connect()
$tache = $svc.GetFolder("\local-ai-lab").GetTask("Hermes-admin")
$fin = "$Base\resultats\$id.code"; $limite = (Get-Date).AddMinutes(65)
$null = $tache.Run($null)
while (-not (Test-Path $fin) -and (Get-Date) -lt $limite) {
    Start-Sleep -Seconds 3
    if ((Test-Path $dem) -and $tache.State -ne 4) { $null = $tache.Run($null) }   # 4 = en cours ; sinon relancer
}
if (-not (Test-Path $fin)) { Write-Output "Pas de resultat apres 65 min (demande $id)."; exit 124 }
Get-Content "$Base\resultats\$id.log" -ErrorAction SilentlyContinue
$code = [int](Get-Content $fin | Select-Object -First 1)
Write-Output "--- code de retour : $code"
exit $code
'@ | Set-Content -Path "$Base\outils\lancer.ps1" -Encoding UTF8

# 4. Tache planifiee (SYSTEM) que l'agent peut declencher (droits lecture + execution sur la tache seulement)
try { $dossierTache = $svc.GetFolder($Dossier) } catch { $dossierTache = $svc.GetFolder("\").CreateFolder($Dossier) }
$def = $svc.NewTask(0)
$def.RegistrationInfo.Description = "local-ai-lab : execute en administrateur les scripts approuves demandes par $Utilisateur"
$def.Settings.MultipleInstances = 2          # une seule a la fois (les demandes en attente sont traitees dans la boucle)
$def.Settings.ExecutionTimeLimit = "PT2H"
$def.Settings.DisallowStartIfOnBatteries = $false
$def.Settings.StopIfGoingOnBatteries = $false
$def.Principal.RunLevel = 1                  # privileges les plus eleves
$action = $def.Actions.Create(0)
$action.Path = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$action.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Base\outils\executer.ps1`""
$sddl = "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;$sid)"
$null = $dossierTache.RegisterTaskDefinition($Tache, $def, 6, "SYSTEM", $null, 5, $sddl)
Write-Host "Installe : dossier $Base, tache $Dossier\$Tache (SYSTEM), declenchable par $Utilisateur."
Write-Host "Approuver un script : powershell -ExecutionPolicy Bypass -File .\Approuver-script-hermes.ps1 -Fichier C:\Users\$Utilisateur\work\...\test.bat"
Write-Host "Test (depuis AiBeast) : ssh -F /opt/data/ssh/config NOM 'powershell -NoProfile -ExecutionPolicy Bypass -File $Base\outils\lancer.ps1'"
