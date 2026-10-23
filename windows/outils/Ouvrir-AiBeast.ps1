# Opens the SSH tunnels to AiBeast (in the background) then the portal in the browser.
# Usage: right-click > Run with PowerShell, or double-click Ouvrir-AiBeast.bat ("Ouvrir" = open)
$ErrorActionPreference = "Stop"
$deja = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -match "-N aibeast" }
if (-not $deja) {
    Write-Host "Opening the tunnels to AiBeast..."
    Start-Process -FilePath "ssh" -ArgumentList "-N", "aibeast" -WindowStyle Hidden
    Start-Sleep -Seconds 3
} else {
    Write-Host "Tunnels already open."
}
$ok = (Test-NetConnection 127.0.0.1 -Port 3010 -WarningAction SilentlyContinue).TcpTestSucceeded
if ($ok) {
    Start-Process "http://127.0.0.1:3010"
} else {
    Write-Host "The portal does not answer on 127.0.0.1:3010." -ForegroundColor Yellow
    Write-Host "Possible causes: VPN not connected, SSH key missing, portal not started (lab start portail)."
    Write-Host "Manual test: ssh aibeast"
    Read-Host "Press Enter to close"
}
