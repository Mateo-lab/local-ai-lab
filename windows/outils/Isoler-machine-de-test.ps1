# Machine de test des agents (Windows) : coupe Internet pour TOUTE la machine et interdit les tunnels SSH
# au compte de l'agent. A lancer EN ADMINISTRATEUR sur la machine de test (pas sur ton PC habituel) :
#
#   powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1                 applique (compte : hermes)
#   powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1 -Utilisateur x  autre compte d'agent
#   powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1 -GarderDns      laisse passer le DNS (port 53)
#   powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1 -Annuler        retire les regles de pare-feu
#
# Ce que fait le script (detail : docs/agent-isolation.md, section « Machine de test ») :
# 1. Pare-feu Windows : regles de BLOCAGE sortant vers toutes les adresses publiques (IPv4 et IPv6). Le reseau
#    local (10.x, 172.16-31.x, 192.168.x, lien local) reste joignable, donc l'agent peut toujours s'y connecter.
#    Une regle de blocage l'emporte sur toutes les autorisations ; un compte sans droits d'administrateur ne peut
#    pas la modifier.
# 2. DNS bloque (port 53, sauf -GarderDns) : sinon des donnees pourraient sortir par des requetes DNS envoyees a la box.
# 3. Serveur SSH : pour le compte de l'agent, aucun tunnel (redirection de port, SOCKS, agent, X11).
# 4. Verifications : connexion Internet et resolution DNS doivent echouer ; affichage de l'etat.
# Consequences : plus d'Internet pour PERSONNE sur cette machine (mises a jour Windows comprises) tant que les regles
# sont actives. Pour une mise a jour ponctuelle : -Annuler, la mise a jour, puis relancer le script.
param(
    [string]$Utilisateur = "hermes",
    [switch]$GarderDns,
    [switch]$Annuler
)
$ErrorActionPreference = "Stop"
$Groupe = "local-ai-lab isolation"
$Dossier = "C:\ProgramData\ssh"

$moi = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $moi.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Lance ce script EN ADMINISTRATEUR (clic droit sur PowerShell > Executer en tant qu'administrateur)." -ForegroundColor Red
    exit 1
}

if ($Annuler) {
    Get-NetFirewallRule -Group $Groupe -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Host "Regles de pare-feu '$Groupe' retirees : la machine a de nouveau acces a Internet."
    Write-Host "(Le verrouillage SSH du compte $Utilisateur reste en place : il ne gene rien.)"
    exit 0
}

# 0. Sauvegardes
$stamp = Get-Date -Format "yyyyMMdd-HHmm"
if (-not (Test-Path $Dossier)) { New-Item -ItemType Directory -Path $Dossier | Out-Null }
netsh advfirewall export "$Dossier\pare-feu-avant-isolation-$stamp.wfw" | Out-Null
Write-Host "Sauvegarde du pare-feu : $Dossier\pare-feu-avant-isolation-$stamp.wfw"

# 1. Pare-feu : actif sur tous les profils, blocage sortant vers Internet
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
Get-NetFirewallRule -Group $Groupe -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$publiques4 = @("0.0.0.0-9.255.255.255", "11.0.0.0-126.255.255.255", "128.0.0.0-169.253.255.255",
                "169.255.0.0-172.15.255.255", "172.32.0.0-192.167.255.255", "192.169.0.0-223.255.255.255")
New-NetFirewallRule -DisplayName "Isolation : pas d'Internet (IPv4)" -Group $Groupe -Direction Outbound `
    -Action Block -RemoteAddress $publiques4 -Profile Any | Out-Null
New-NetFirewallRule -DisplayName "Isolation : pas d'Internet (IPv6)" -Group $Groupe -Direction Outbound `
    -Action Block -RemoteAddress "2000::/3" -Profile Any | Out-Null
if (-not $GarderDns) {
    New-NetFirewallRule -DisplayName "Isolation : pas de DNS (UDP)" -Group $Groupe -Direction Outbound `
        -Action Block -Protocol UDP -RemotePort 53 -Profile Any | Out-Null
    New-NetFirewallRule -DisplayName "Isolation : pas de DNS (TCP)" -Group $Groupe -Direction Outbound `
        -Action Block -Protocol TCP -RemotePort 53 -Profile Any | Out-Null
}
Write-Host "Pare-feu : Internet bloque pour toute la machine$(if (-not $GarderDns) { ', DNS bloque' })."

# 2. Serveur SSH : aucun tunnel pour le compte de l'agent
$cfg = Join-Path $Dossier "sshd_config"
if (Test-Path $cfg) {
    Copy-Item $cfg "$cfg.avant-isolation-$stamp"
    $lignes = @(Get-Content $cfg)
    $match = @($lignes | Select-String -Pattern '^\s*Match\s')
    $dernier = if ($match.Count -gt 0) { $match[-1] } else { $null }
    if ($dernier -and ($dernier.Line -match "^\s*Match\s+User\s+$([regex]::Escape($Utilisateur))\s*$")) {
        $bloc = $lignes[($dernier.LineNumber)..($lignes.Count - 1)]
        $options = @("AllowTcpForwarding no", "AllowStreamLocalForwarding no", "PermitTunnel no",
                     "AllowAgentForwarding no", "X11Forwarding no", "GatewayPorts no")
        foreach ($o in $options) {
            $nom = $o.Split(" ")[0]
            if (-not ($bloc | Where-Object { $_ -match "^\s*$nom\s" })) { Add-Content -Path $cfg -Value "    $o" -Encoding ascii }
        }
        & "$env:WINDIR\System32\OpenSSH\sshd.exe" -t
        if ($LASTEXITCODE -ne 0) {
            Copy-Item "$cfg.avant-isolation-$stamp" $cfg -Force
            Write-Host "sshd_config refuse par 'sshd -t' : version precedente remise, serveur SSH inchange." -ForegroundColor Red
        } else {
            Restart-Service sshd
            Write-Host "Serveur SSH : tunnels interdits pour $Utilisateur (sauvegarde : $cfg.avant-isolation-$stamp)."
        }
    } else {
        Write-Host "ATTENTION : le dernier bloc de $cfg n'est pas 'Match User $Utilisateur'. Ajoute a la main, a la fin du bloc" -ForegroundColor Yellow
        Write-Host "  de ce compte : AllowTcpForwarding no / AllowStreamLocalForwarding no / PermitTunnel no / AllowAgentForwarding no / X11Forwarding no"
    }
} else {
    Write-Host "ATTENTION : $cfg introuvable (serveur OpenSSH non installe ?)." -ForegroundColor Yellow
}
$cles = Join-Path $Dossier "$($Utilisateur)_authorized_keys"
if (Test-Path $cles) {
    if (@(Get-Content $cles | Where-Object { $_ -match '^\s*ssh-' }).Count -gt 0) {
        Write-Host "ATTENTION : une cle de $cles n'a pas l'option 'restrict' en tete de ligne." -ForegroundColor Yellow
    } else { Write-Host "Cles de $Utilisateur : option 'restrict' presente." }
}

# 3. Verifications
function Test-Tcp([string]$h, [int]$p) {
    try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync($h, $p).Wait(4000); $c.Close(); return $ok }
    catch { return $false }
}
Write-Host "--- Verifications ---"
$i = Test-Tcp "1.1.1.1" 443
Write-Host ("Internet (1.1.1.1:443)      : " + $(if ($i) { "JOIGNABLE  <- probleme" } else { "bloque (bien)" }))
$d = $false; try { $d = [Net.Dns]::GetHostAddressesAsync("example.com").Wait(5000) } catch { }   # 5 s au plus : DNS bloque = pas de reponse
Write-Host ("Resolution DNS example.com  : " + $(if ($d) { if ($GarderDns) { "resolu (DNS garde volontairement)" } else { "RESOLU  <- probleme (cache ? relancer apres 'ipconfig /flushdns')" } } else { "bloquee (bien)" }))
Get-NetFirewallRule -Group $Groupe | Format-Table DisplayName, Enabled, Direction, Action -AutoSize
