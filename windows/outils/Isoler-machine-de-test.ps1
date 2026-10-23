# Agents' test machine (Windows): cuts the Internet for the WHOLE machine and forbids SSH tunnels
# for the agent's account ("Isoler" = isolate). To run AS ADMINISTRATOR on the test machine (not on your usual PC):
#
#   powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1               applies (account: hermes)
#   powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1 -User x       another agent account
#   powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1 -KeepDns      lets DNS through (port 53)
#   powershell -ExecutionPolicy Bypass -File .\Isoler-machine-de-test.ps1 -Undo         removes the firewall rules
# (The former French parameter names -Utilisateur, -GarderDns and -Annuler still work.)
#
# What the script does (details: docs/agent-isolation.md, "The test machine" section):
# 1. Windows firewall: outbound BLOCK rules to every public address (IPv4 and IPv6). The local
#    network (10.x, 172.16-31.x, 192.168.x, link-local) stays reachable, so the agent can still connect to it.
#    A block rule wins over every allow rule; an account without administrator rights cannot change it.
# 2. DNS blocked (port 53, unless -KeepDns): otherwise data could leave through DNS queries sent to the router.
# 3. SSH server: for the agent's account, no tunnel (port forwarding, SOCKS, agent, X11).
# 4. Checks: Internet connection and DNS resolution must fail; the state is shown.
# Consequences: no more Internet for ANYONE on this machine (Windows updates included) while the rules
# are active. For a one-off update: -Undo, the update, then run the script again.
param(
    [Alias('User')][string]$Utilisateur = "hermes",
    [Alias('KeepDns')][switch]$GarderDns,
    [Alias('Undo')][switch]$Annuler
)
$ErrorActionPreference = "Stop"
$Groupe = "local-ai-lab isolation"
$Dossier = "C:\ProgramData\ssh"

$moi = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $moi.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Run this script AS ADMINISTRATOR (right-click PowerShell > Run as administrator)." -ForegroundColor Red
    exit 1
}

if ($Annuler) {
    Get-NetFirewallRule -Group $Groupe -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Host "Firewall rules '$Groupe' removed: the machine has Internet access again."
    Write-Host "(The SSH lock of the $Utilisateur account stays in place: it gets in nobody's way.)"
    exit 0
}

# 0. Backups
$stamp = Get-Date -Format "yyyyMMdd-HHmm"
if (-not (Test-Path $Dossier)) { New-Item -ItemType Directory -Path $Dossier | Out-Null }
netsh advfirewall export "$Dossier\firewall-before-isolation-$stamp.wfw" | Out-Null
Write-Host "Firewall backup: $Dossier\firewall-before-isolation-$stamp.wfw"

# 1. Firewall: enabled on every profile, outbound block to the Internet
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
Get-NetFirewallRule -Group $Groupe -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$publiques4 = @("0.0.0.0-9.255.255.255", "11.0.0.0-126.255.255.255", "128.0.0.0-169.253.255.255",
                "169.255.0.0-172.15.255.255", "172.32.0.0-192.167.255.255", "192.169.0.0-223.255.255.255")
New-NetFirewallRule -DisplayName "Isolation: no Internet (IPv4)" -Group $Groupe -Direction Outbound `
    -Action Block -RemoteAddress $publiques4 -Profile Any | Out-Null
New-NetFirewallRule -DisplayName "Isolation: no Internet (IPv6)" -Group $Groupe -Direction Outbound `
    -Action Block -RemoteAddress "2000::/3" -Profile Any | Out-Null
if (-not $GarderDns) {
    New-NetFirewallRule -DisplayName "Isolation: no DNS (UDP)" -Group $Groupe -Direction Outbound `
        -Action Block -Protocol UDP -RemotePort 53 -Profile Any | Out-Null
    New-NetFirewallRule -DisplayName "Isolation: no DNS (TCP)" -Group $Groupe -Direction Outbound `
        -Action Block -Protocol TCP -RemotePort 53 -Profile Any | Out-Null
}
Write-Host "Firewall: Internet blocked for the whole machine$(if (-not $GarderDns) { ', DNS blocked' })."

# 2. SSH server: no tunnel for the agent's account
$cfg = Join-Path $Dossier "sshd_config"
if (Test-Path $cfg) {
    Copy-Item $cfg "$cfg.before-isolation-$stamp"
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
            Copy-Item "$cfg.before-isolation-$stamp" $cfg -Force
            Write-Host "sshd_config refused by 'sshd -t': previous version restored, SSH server unchanged." -ForegroundColor Red
        } else {
            Restart-Service sshd
            Write-Host "SSH server: tunnels forbidden for $Utilisateur (backup: $cfg.before-isolation-$stamp)."
        }
    } else {
        Write-Host "WARNING: the last block of $cfg is not 'Match User $Utilisateur'. Add by hand, at the end of the block" -ForegroundColor Yellow
        Write-Host "  of that account: AllowTcpForwarding no / AllowStreamLocalForwarding no / PermitTunnel no / AllowAgentForwarding no / X11Forwarding no"
    }
} else {
    Write-Host "WARNING: $cfg not found (OpenSSH server not installed?)." -ForegroundColor Yellow
}
$cles = Join-Path $Dossier "$($Utilisateur)_authorized_keys"
if (Test-Path $cles) {
    if (@(Get-Content $cles | Where-Object { $_ -match '^\s*ssh-' }).Count -gt 0) {
        Write-Host "WARNING: a key in $cles does not start with the 'restrict' option." -ForegroundColor Yellow
    } else { Write-Host "Keys of $($Utilisateur): 'restrict' option present." }
}

# 3. Checks
function Test-Tcp([string]$h, [int]$p) {
    try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync($h, $p).Wait(4000); $c.Close(); return $ok }
    catch { return $false }
}
Write-Host "--- Checks ---"
$i = Test-Tcp "1.1.1.1" 443
Write-Host ("Internet (1.1.1.1:443)      : " + $(if ($i) { "REACHABLE  <- problem" } else { "blocked (good)" }))
$d = $false; try { $d = [Net.Dns]::GetHostAddressesAsync("example.com").Wait(5000) } catch { }   # 5 s at most: DNS blocked = no answer
Write-Host ("DNS resolution example.com  : " + $(if ($d) { if ($GarderDns) { "resolved (DNS kept on purpose)" } else { "RESOLVED  <- problem (cache? run again after 'ipconfig /flushdns')" } } else { "blocked (good)" }))
Get-NetFirewallRule -Group $Groupe | Format-Table DisplayName, Enabled, Direction, Action -AutoSize
