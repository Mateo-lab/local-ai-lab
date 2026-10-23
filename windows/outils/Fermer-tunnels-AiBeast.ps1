# Closes the SSH tunnels opened by Ouvrir-AiBeast.ps1 ("Fermer" = close)
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
    Where-Object { $_.CommandLine -match "-N aibeast" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Tunnel closed (PID $($_.ProcessId))" }
