# Menu AiBeast : les actions courantes sans taper de commande.
# Utilisation : double-clic sur AiBeast-Menu.bat (menu), ou sur un raccourci direct (AiBeast-Images.bat, AiBeast-Normal.bat...).
# Prérequis : la clé SSH et l'entrée "Host aibeast" générée par « lab client » sur AiBeast (voir docs\acces-distant.md).
param([string]$Action = "menu")
$Hote = "aibeast"
$Lab  = "~/.local/bin/lab"
$RegexProjet  = '^[a-z0-9][a-z0-9_-]{0,40}$'
$RegexBranche = '^agent/[A-Za-z0-9._-]+$'

# Lance `lab ...` sur AiBeast. -Tty : terminal interactif (nécessaire pour Hermes et les actions longues sous tmux).
# ClearAllForwardings : sans cela, ssh essaie d'ouvrir les tunnels déjà ouverts et s'arrête (ExitOnForwardFailure).
# Les arguments passés ici ne contiennent que des noms déjà validés (projets, branches, langages).
function Invoke-Lab {
    param([string]$Commande, [switch]$Tty)
    if ($Tty) {
        # Terminal interactif : Start-Process donne à ssh la console elle-même (un simple "& ssh | Out-Host" casserait tmux et Hermes).
        $arguments = "-t -o ClearAllForwardings=yes $Hote `"$Lab $Commande`""
        $proc = Start-Process -FilePath "ssh" -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        return $proc.ExitCode
    }
    & ssh -o ClearAllForwardings=yes $Hote "$Lab $Commande" | Out-Host
    return $LASTEXITCODE
}

# Même chose mais renvoie le texte (une ligne par élément) au lieu de l'afficher.
function Get-Lab {
    param([string]$Commande)
    $sortie = & ssh -o ClearAllForwardings=yes $Hote "$Lab $Commande"
    return @($sortie | Where-Object { $_ -ne $null -and "$_".Trim() -ne "" })
}

function Test-Connexion {
    & ssh -o BatchMode=yes -o ConnectTimeout=8 -o ClearAllForwardings=yes $Hote "echo ok" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Impossible de joindre AiBeast par SSH." -ForegroundColor Yellow
        Write-Host "Causes possibles : VPN non connecté, clé SSH non chargée, entrée 'Host aibeast' absente de $env:USERPROFILE\.ssh\config (voir lab client)."
        Write-Host "Test manuel : ssh aibeast"
        return $false
    }
    return $true
}

function Attendre { Write-Host ""; Read-Host "Appuie sur Entrée pour continuer" | Out-Null }

function Ouvrir-Navigateur([string]$Url) {
    $port = ([Uri]$Url).Port
    if ((Test-NetConnection 127.0.0.1 -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded) { Start-Process $Url }
    else { Write-Host "Le tunnel vers $Url n'est pas ouvert : lance d'abord Ouvrir-AiBeast.bat." -ForegroundColor Yellow }
}

function Action-Images {
    Write-Host "Mode images : décharge le modèle de langage, démarre ComfyUI (jusqu'à 3 minutes)..." -ForegroundColor Cyan
    $rc = Invoke-Lab "mode images"
    if ($rc -eq 0) { Ouvrir-Navigateur "http://127.0.0.1:8188" }
    Write-Host "Pour revenir aux modèles de langage : AiBeast-Normal.bat" -ForegroundColor Cyan
}

function Action-Hermes {
    while ($true) {
        Write-Host ""
        Write-Host "=== Hermes : développement ===" -ForegroundColor Cyan
        Write-Host " 1) Relire et fusionner le travail de l'agent"
        Write-Host " 2) Ouvrir Hermes dans un projet"
        Write-Host " 3) Nouveau projet"
        Write-Host " 0) Retour"
        $c = Read-Host "Choix"
        switch ($c) {
            "1" { Hermes-Fusion }
            "2" { Hermes-Ouvrir }
            "3" { Hermes-Nouveau }
            "0" { return }
        }
    }
}

function Hermes-Fusion {
    $lignes = Get-Lab "dev pending"
    $items = @()
    foreach ($l in $lignes) {
        $p = "$l" -split "`t"
        # Les noms viennent d'AiBeast (choisis en partie par l'agent) : on les revalide ici avant de les mettre dans une commande.
        if ($p.Count -eq 3 -and $p[0] -match $RegexProjet -and $p[1] -match $RegexBranche -and $p[2] -match '^\d+$') {
            $items += [pscustomobject]@{ Projet = $p[0]; Branche = $p[1]; Commits = $p[2] }
        }
    }
    if ($items.Count -eq 0) { Write-Host "Aucune branche d'agent à relire." -ForegroundColor Green; return }
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Host (" {0}) {1}  {2}  ({3} commit(s))" -f ($i + 1), $items[$i].Projet, $items[$i].Branche, $items[$i].Commits)
    }
    $n = Read-Host "Numéro (Entrée pour annuler)"
    if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $items.Count) { return }
    $it = $items[[int]$n - 1]
    Write-Host ""
    Invoke-Lab "dev review $($it.Projet) $($it.Branche)" | Out-Null
    if ((Read-Host "Voir le diff complet ? (o/N)") -match '^[oOyY]') {
        Invoke-Lab "dev review $($it.Projet) $($it.Branche) --diff" | Out-Null
    }
    Write-Host ""
    Write-Host "La fusion relance d'abord les tests dans le bac à sable ; si ils échouent, rien n'est fusionné." -ForegroundColor Cyan
    if ((Read-Host "Fusionner $($it.Branche) dans main ? Tu as relu le diff ? (o/N)") -match '^[oOyY]') {
        Invoke-Lab "dev merge $($it.Projet) $($it.Branche) --yes" | Out-Null
    } else { Write-Host "Annulé." }
}

function Hermes-Ouvrir {
    $noms = @(Get-Lab "dev names" | Where-Object { $_ -match $RegexProjet })
    if ($noms.Count -eq 0) { Write-Host "Aucun projet : crée-en un (choix 3)." -ForegroundColor Yellow; return }
    for ($i = 0; $i -lt $noms.Count; $i++) { Write-Host (" {0}) {1}" -f ($i + 1), $noms[$i]) }
    $n = Read-Host "Numéro (Entrée pour annuler)"
    if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $noms.Count) { return }
    Write-Host "Hermes s'ouvre dans ce terminal ; /exit pour le quitter." -ForegroundColor Cyan
    Invoke-Lab "dev start $($noms[[int]$n - 1])" -Tty | Out-Null
}

function Hermes-Nouveau {
    $nom = Read-Host "Nom du projet (minuscules, chiffres, - et _)"
    if ($nom -notmatch $RegexProjet) { Write-Host "Nom invalide." -ForegroundColor Yellow; return }
    $lang = Read-Host "Langage : python, node, shell ou autre (Entrée = python)"
    if ([string]::IsNullOrWhiteSpace($lang)) { $lang = "python" }
    if ($lang -notin @("python", "node", "shell", "autre")) { Write-Host "Langage inconnu." -ForegroundColor Yellow; return }
    Invoke-Lab "dev new $nom $lang" | Out-Null
}

function Executer([string]$a) {
    switch ($a) {
        "images"  { Action-Images }
        "normal"  { Invoke-Lab "mode normal" | Out-Null }
        "agents"  { Invoke-Lab "mode agents" | Out-Null }
        "status"  { Invoke-Lab "mode status" | Out-Null }
        "doctor"  { Invoke-Lab "doctor" | Out-Null }
        "update"  { Write-Host "Mise à jour (session tmux 'lab-update' : elle continue si la connexion coupe)..." -ForegroundColor Cyan; Invoke-Lab "tmux update" -Tty | Out-Null }
        "backup"  { Write-Host "Sauvegarde (session tmux 'lab-backup')..." -ForegroundColor Cyan; Invoke-Lab "tmux backup" -Tty | Out-Null }
        "hermes"  { Action-Hermes }
        "portail" { & (Join-Path $PSScriptRoot "Ouvrir-AiBeast.ps1") }
        default   { Write-Host "Action inconnue : $a" -ForegroundColor Yellow }
    }
}

if (-not (Test-Connexion)) { Read-Host "Appuie sur Entrée pour fermer" | Out-Null; exit 1 }

if ($Action -ne "menu") {
    Executer $Action
    Write-Host ""
    Read-Host "Terminé. Appuie sur Entrée pour fermer" | Out-Null
    exit 0
}

while ($true) {
    Clear-Host
    Write-Host "=== AiBeast ===" -ForegroundColor Cyan
    Write-Host " 1) Mode IMAGES  (décharge le modèle, démarre ComfyUI)"
    Write-Host " 2) Mode NORMAL  (arrête ComfyUI, rétablit tout)"
    Write-Host " 3) Mode AGENTS  (libère la VRAM pour Hermes)"
    Write-Host " 4) État         (mode, VRAM, modèles chargés)"
    Write-Host " 5) Santé        (lab doctor)"
    Write-Host " 6) Mise à jour  (images Docker)"
    Write-Host " 7) Sauvegarde"
    Write-Host " 8) Hermes       (relire / fusionner / ouvrir un projet)"
    Write-Host " 9) Ouvrir le portail dans le navigateur"
    Write-Host " 0) Quitter"
    $c = Read-Host "Choix"
    $map = @{ "1" = "images"; "2" = "normal"; "3" = "agents"; "4" = "status"; "5" = "doctor"; "6" = "update"; "7" = "backup"; "8" = "hermes"; "9" = "portail" }
    if ($c -eq "0") { break }
    if ($map.ContainsKey($c)) { Executer $map[$c]; if ($c -ne "8") { Attendre } }
}
