# Ferme les tunnels SSH ouverts par Ouvrir-AiBeast.ps1
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
    Where-Object { $_.CommandLine -match "-N aibeast" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Tunnel fermé (PID $($_.ProcessId))" }
