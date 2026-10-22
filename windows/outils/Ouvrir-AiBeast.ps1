# Ouvre les tunnels SSH vers AiBeast (en arrière-plan) puis le portail dans le navigateur.
# Utilisation : clic droit > Exécuter avec PowerShell, ou double-clic sur Ouvrir-AiBeast.bat
$ErrorActionPreference = "Stop"
$deja = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -match "-N aibeast" }
if (-not $deja) {
    Write-Host "Ouverture des tunnels vers AiBeast..."
    Start-Process -FilePath "ssh" -ArgumentList "-N", "aibeast" -WindowStyle Hidden
    Start-Sleep -Seconds 3
} else {
    Write-Host "Tunnels déjà actifs."
}
$ok = (Test-NetConnection 127.0.0.1 -Port 3010 -WarningAction SilentlyContinue).TcpTestSucceeded
if ($ok) {
    Start-Process "http://127.0.0.1:3010"
} else {
    Write-Host "Le portail ne répond pas sur 127.0.0.1:3010." -ForegroundColor Yellow
    Write-Host "Causes possibles : VPN non connecté, clé SSH absente, portail non démarré (lab start portail)."
    Write-Host "Test manuel : ssh aibeast"
    Read-Host "Appuie sur Entrée pour fermer"
}
