# AiBeast console: a window with buttons to do everything (tunnels, browser, deployment, modes, backups, Hermes).
# Usage: double-click AiBeast.bat. Prerequisites: VPN connected, SSH key and "Host aibeast" entry (see docs\remote-access.md).
# Long actions open in their own window (they ask questions or show results): the existing scripts are reused as is.
# (Function names are French, as in the original version.)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Dossier = $PSScriptRoot
$Ports = [ordered]@{ "Portal" = 3010; "Panel" = 3011; "ComfyUI" = 8188; "Open WebUI" = 3000; "n8n" = 5678 }

function Test-Port([int]$port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $r = $c.BeginConnect("127.0.0.1", $port, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne(250)
        if ($ok) { try { $c.EndConnect($r) } catch { $ok = $false } }
        return $ok
    } catch { return $false } finally { $c.Close() }
}

function Message([string]$texte, [bool]$erreur = $false) {
    $script:lblMessage.Text = $texte
    $script:lblMessage.ForeColor = if ($erreur) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DimGray }
}

function Actualiser-Etat {
    if (Test-Port 3010) {
        $script:lblTunnels.Text = "Tunnels: open"
        $script:lblTunnels.ForeColor = [System.Drawing.Color]::SeaGreen
    } else {
        $script:lblTunnels.Text = "Tunnels: closed (click 'Open the tunnels')"
        $script:lblTunnels.ForeColor = [System.Drawing.Color]::Firebrick
    }
}

# Runs a PowerShell script of the folder in its own window (it stays open until Enter, like the .bat files).
function Lancer-Fenetre([string]$script, [string]$arguments = "") {
    $chemin = Join-Path $Dossier $script
    if (-not (Test-Path $chemin)) { Message "File not found: $script" $true; return }
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$chemin`" $arguments"
    Start-Process -FilePath "powershell.exe" -ArgumentList $a | Out-Null
}

function Confirmer([string]$texte) {
    $r = [System.Windows.Forms.MessageBox]::Show($texte, "AiBeast", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Ouvrir-Tunnels {
    $deja = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -match "-N aibeast" }
    if ($deja) { Message "The tunnels are already open."; Actualiser-Etat; return }
    Message "Opening the tunnels..."
    $script:form.Refresh()
    Start-Process -FilePath "ssh" -ArgumentList "-N", "aibeast" -WindowStyle Hidden
    for ($i = 0; $i -lt 16; $i++) { Start-Sleep -Milliseconds 500; if (Test-Port 3010) { break } }
    Actualiser-Etat
    if (Test-Port 3010) { Message "Tunnels open." }
    else { Message "The tunnels do not open. Check the VPN and the SSH key ('Test the connection' button)." $true }
}

function Fermer-Tunnels {
    $n = 0
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -match "-N aibeast" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $n++ }
    Start-Sleep -Milliseconds 400
    Actualiser-Etat
    if ($n -gt 0) { Message "Tunnels closed." } else { Message "No tunnel to close." }
}

function Ouvrir-Page([string]$nom) {
    $port = $Ports[$nom]
    if (Test-Port $port) { Start-Process "http://127.0.0.1:$port" | Out-Null; Message "$nom opened in the browser." }
    else { Message "$nom does not answer: open the tunnels first (and check that the service runs on AiBeast)." $true }
}

function Executer([string]$cle) {
    switch ($cle) {
        "tunnels-ouvrir" { Ouvrir-Tunnels }
        "tunnels-fermer" { Fermer-Tunnels }
        "tester"         { Lancer-Fenetre "AiBeast.ps1" "-Action status"; Message "Test started in a window (it connects to AiBeast)." }
        "web-Portal"     { Ouvrir-Page "Portal" }
        "web-Panel"      { Ouvrir-Page "Panel" }
        "web-ComfyUI"    { Ouvrir-Page "ComfyUI" }
        "web-Open WebUI" { Ouvrir-Page "Open WebUI" }
        "web-n8n"        { Ouvrir-Page "n8n" }
        "deployer"       { if (Confirmer "Send the new version of the lab to AiBeast?`n`nA safety backup is made before replacing the files.") { Lancer-Fenetre "Deployer-sur-AiBeast.ps1" } }
        "copie-sauvegardes" { Lancer-Fenetre "Sauvegarder-AiBeast-hors-machine.ps1" }
        "images"         { Lancer-Fenetre "AiBeast.ps1" "-Action images" }
        "normal"         { Lancer-Fenetre "AiBeast.ps1" "-Action normal" }
        "agents"         { Lancer-Fenetre "AiBeast.ps1" "-Action agents-hermes" }
        "agents-hermes"  { Lancer-Fenetre "AiBeast.ps1" "-Action agents-hermes" }
        "agents-openclaw" { Lancer-Fenetre "AiBeast.ps1" "-Action agents-openclaw" }
        "fermer-hermes"  { if (Confirmer "Close the Hermes session(s) on AiBeast?`n`nThe conversation in progress stops. Hermes's memory and the project files are kept.") { Lancer-Fenetre "AiBeast.ps1" "-Action close-hermes -Yes" } }
        "status"         { Lancer-Fenetre "AiBeast.ps1" "-Action status" }
        "doctor"         { Lancer-Fenetre "AiBeast.ps1" "-Action doctor" }
        "update"         { if (Confirmer "Start the update of the Docker images on AiBeast?`n`nA backup is made first. This can take a long time.") { Lancer-Fenetre "AiBeast.ps1" "-Action update" } }
        "backup"         { if (Confirmer "Start a backup on AiBeast now?") { Lancer-Fenetre "AiBeast.ps1" "-Action backup" } }
        "hermes"         { Lancer-Fenetre "AiBeast.ps1" "-Action hermes" }
        "gateway-start"  { Lancer-Fenetre "AiBeast.ps1" "-Action gateway-start";  Message "Hermes Desktop gateway starting in a window. Open the Hermes Desktop app on http://127.0.0.1:9119 (tunnels must be open)." }
        "gateway-stop"   { Lancer-Fenetre "AiBeast.ps1" "-Action gateway-stop";   Message "Stopping the Hermes Desktop gateway." }
        "gateway-status" { Lancer-Fenetre "AiBeast.ps1" "-Action gateway-status" }
    }
}

# ---------- Window ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "AiBeast"
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object System.Drawing.Size(560, 640)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

$lblTitre = New-Object System.Windows.Forms.Label
$lblTitre.Text = "AiBeast"
$lblTitre.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$lblTitre.Location = New-Object System.Drawing.Point(16, 10)
$lblTitre.AutoSize = $true
$form.Controls.Add($lblTitre)

$lblTunnels = New-Object System.Windows.Forms.Label
$lblTunnels.Location = New-Object System.Drawing.Point(18, 46)
$lblTunnels.Size = New-Object System.Drawing.Size(524, 22)
$form.Controls.Add($lblTunnels)

$y = 76
function Ajouter-Groupe([string]$titre, $boutons) {
    $colonnes = 3
    $lignes = [math]::Ceiling($boutons.Count / $colonnes)
    $hauteur = 28 + $lignes * 40 + 6
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $titre
    $g.Location = New-Object System.Drawing.Point(12, $script:y)
    $g.Size = New-Object System.Drawing.Size(536, $hauteur)
    for ($i = 0; $i -lt $boutons.Count; $i++) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $boutons[$i][0]
        $b.Tag = $boutons[$i][1]
        $b.Size = New-Object System.Drawing.Size(164, 34)
        $b.Location = New-Object System.Drawing.Point((8 + ($i % $colonnes) * 172), (24 + [math]::Floor($i / $colonnes) * 40))
        $b.Add_Click({ param($sender, $e) Executer ([string]$sender.Tag) })
        $g.Controls.Add($b)
    }
    $script:form.Controls.Add($g)
    $script:y += $hauteur + 8
}

Ajouter-Groupe "1. Connection to AiBeast" @(
    @("Open the tunnels", "tunnels-ouvrir"), @("Close the tunnels", "tunnels-fermer"), @("Test the connection", "tester"))
Ajouter-Groupe "2. Open in the browser" @(
    @("Portal", "web-Portal"), @("Button panel", "web-Panel"), @("ComfyUI (images)", "web-ComfyUI"),
    @("Open WebUI (chat)", "web-Open WebUI"), @("n8n (automations)", "web-n8n"))
Ajouter-Groupe "3. Delivery and backup copies" @(
    @("Deploy the new version", "deployer"), @("Copy the backups to this PC", "copie-sauvegardes"))
Ajouter-Groupe "4. Graphics card modes" @(
    @("Images mode", "images"), @("Normal mode", "normal"),
    @("State", "status"), @("Health (diagnosis)", "doctor"))
Ajouter-Groupe "5. Agents: only one at a time" @(
    @("Hermes only", "agents-hermes"), @("OpenClaw only", "agents-openclaw"), @("Close the Hermes session", "fermer-hermes"))
Ajouter-Groupe "6. Maintenance and Hermes" @(
    @("Update", "update"), @("Backup", "backup"), @("Hermes (projects, review)", "hermes"))
Ajouter-Groupe "7. Hermes Desktop (graphical interface)" @(
    @("Start gateway", "gateway-start"), @("Stop gateway", "gateway-stop"), @("Gateway status", "gateway-status"))

$lblMessage = New-Object System.Windows.Forms.Label
$lblMessage.Location = New-Object System.Drawing.Point(16, ($y + 2))
$lblMessage.Size = New-Object System.Drawing.Size(526, 40)
$lblMessage.ForeColor = [System.Drawing.Color]::DimGray
$lblMessage.Text = "Ready."
$form.Controls.Add($lblMessage)
$form.ClientSize = New-Object System.Drawing.Size(560, ($y + 48))

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Actualiser-Etat })
$timer.Start()
$form.Add_Shown({ Actualiser-Etat })

[void]$form.ShowDialog()
$timer.Stop()
