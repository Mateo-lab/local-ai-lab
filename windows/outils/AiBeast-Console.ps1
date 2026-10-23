# Console AiBeast : une fenêtre avec des boutons pour tout faire (tunnels, navigateur, déploiement, modes, sauvegardes, Hermes).
# Utilisation : double-clic sur AiBeast.bat. Prérequis : VPN connecté, clé SSH et entrée "Host aibeast" (voir docs\remote-access.md).
# Les actions longues s'ouvrent dans leur propre fenêtre (elles posent des questions ou affichent des résultats) : les scripts existants sont réutilisés tels quels.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Dossier = $PSScriptRoot
$Ports = [ordered]@{ "Portail" = 3010; "Panneau" = 3011; "ComfyUI" = 8188; "Open WebUI" = 3000; "n8n" = 5678 }

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
        $script:lblTunnels.Text = "Tunnels : ouverts"
        $script:lblTunnels.ForeColor = [System.Drawing.Color]::SeaGreen
    } else {
        $script:lblTunnels.Text = "Tunnels : fermés (clique sur « Ouvrir les tunnels »)"
        $script:lblTunnels.ForeColor = [System.Drawing.Color]::Firebrick
    }
}

# Lance un script PowerShell du dossier dans sa propre fenêtre (elle reste ouverte jusqu'à Entrée, comme les .bat).
function Lancer-Fenetre([string]$script, [string]$arguments = "") {
    $chemin = Join-Path $Dossier $script
    if (-not (Test-Path $chemin)) { Message "Fichier introuvable : $script" $true; return }
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$chemin`" $arguments"
    Start-Process -FilePath "powershell.exe" -ArgumentList $a | Out-Null
}

function Confirmer([string]$texte) {
    $r = [System.Windows.Forms.MessageBox]::Show($texte, "AiBeast", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Ouvrir-Tunnels {
    $deja = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -match "-N aibeast" }
    if ($deja) { Message "Les tunnels sont déjà ouverts."; Actualiser-Etat; return }
    Message "Ouverture des tunnels..."
    $script:form.Refresh()
    Start-Process -FilePath "ssh" -ArgumentList "-N", "aibeast" -WindowStyle Hidden
    for ($i = 0; $i -lt 16; $i++) { Start-Sleep -Milliseconds 500; if (Test-Port 3010) { break } }
    Actualiser-Etat
    if (Test-Port 3010) { Message "Tunnels ouverts." }
    else { Message "Les tunnels ne s'ouvrent pas. Vérifie le VPN et la clé SSH (bouton « Tester la connexion »)." $true }
}

function Fermer-Tunnels {
    $n = 0
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object { $_.CommandLine -match "-N aibeast" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; $n++ }
    Start-Sleep -Milliseconds 400
    Actualiser-Etat
    if ($n -gt 0) { Message "Tunnels fermés." } else { Message "Aucun tunnel à fermer." }
}

function Ouvrir-Page([string]$nom) {
    $port = $Ports[$nom]
    if (Test-Port $port) { Start-Process "http://127.0.0.1:$port" | Out-Null; Message "$nom ouvert dans le navigateur." }
    else { Message "$nom ne répond pas : ouvre d'abord les tunnels (et vérifie que le service tourne sur AiBeast)." $true }
}

function Executer([string]$cle) {
    switch ($cle) {
        "tunnels-ouvrir" { Ouvrir-Tunnels }
        "tunnels-fermer" { Fermer-Tunnels }
        "tester"         { Lancer-Fenetre "AiBeast.ps1" "-Action status"; Message "Test lancé dans une fenêtre (il se connecte à AiBeast)." }
        "web-Portail"    { Ouvrir-Page "Portail" }
        "web-Panneau"    { Ouvrir-Page "Panneau" }
        "web-ComfyUI"    { Ouvrir-Page "ComfyUI" }
        "web-Open WebUI" { Ouvrir-Page "Open WebUI" }
        "web-n8n"        { Ouvrir-Page "n8n" }
        "deployer"       { if (Confirmer "Envoyer la nouvelle version du lab sur AiBeast ?`n`nUne sauvegarde de sécurité est faite avant de remplacer les fichiers.") { Lancer-Fenetre "Deployer-sur-AiBeast.ps1" } }
        "copie-sauvegardes" { Lancer-Fenetre "Sauvegarder-AiBeast-hors-machine.ps1" }
        "images"         { Lancer-Fenetre "AiBeast.ps1" "-Action images" }
        "normal"         { Lancer-Fenetre "AiBeast.ps1" "-Action normal" }
        "agents"         { Lancer-Fenetre "AiBeast.ps1" "-Action agents" }
        "status"         { Lancer-Fenetre "AiBeast.ps1" "-Action status" }
        "doctor"         { Lancer-Fenetre "AiBeast.ps1" "-Action doctor" }
        "update"         { if (Confirmer "Lancer la mise à jour des images Docker sur AiBeast ?`n`nUne sauvegarde est faite avant. Cela peut durer longtemps.") { Lancer-Fenetre "AiBeast.ps1" "-Action update" } }
        "backup"         { if (Confirmer "Lancer une sauvegarde sur AiBeast maintenant ?") { Lancer-Fenetre "AiBeast.ps1" "-Action backup" } }
        "hermes"         { Lancer-Fenetre "AiBeast.ps1" "-Action hermes" }
    }
}

# ---------- Fenêtre ----------
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

Ajouter-Groupe "1. Connexion à AiBeast" @(
    @("Ouvrir les tunnels", "tunnels-ouvrir"), @("Fermer les tunnels", "tunnels-fermer"), @("Tester la connexion", "tester"))
Ajouter-Groupe "2. Ouvrir dans le navigateur" @(
    @("Portail", "web-Portail"), @("Panneau de boutons", "web-Panneau"), @("ComfyUI (images)", "web-ComfyUI"),
    @("Open WebUI (chat)", "web-Open WebUI"), @("n8n (automatisations)", "web-n8n"))
Ajouter-Groupe "3. Livraison et copies de sauvegarde" @(
    @("Déployer la nouvelle version", "deployer"), @("Copier les sauvegardes sur ce PC", "copie-sauvegardes"))
Ajouter-Groupe "4. Modes de la carte graphique" @(
    @("Mode images", "images"), @("Mode normal", "normal"), @("Mode agents", "agents"),
    @("État", "status"), @("Santé (diagnostic)", "doctor"))
Ajouter-Groupe "5. Maintenance et Hermes" @(
    @("Mise à jour", "update"), @("Sauvegarde", "backup"), @("Hermes (projets, revue)", "hermes"))

$lblMessage = New-Object System.Windows.Forms.Label
$lblMessage.Location = New-Object System.Drawing.Point(16, ($y + 2))
$lblMessage.Size = New-Object System.Drawing.Size(526, 40)
$lblMessage.ForeColor = [System.Drawing.Color]::DimGray
$lblMessage.Text = "Prêt."
$form.Controls.Add($lblMessage)
$form.ClientSize = New-Object System.Drawing.Size(560, ($y + 48))

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Actualiser-Etat })
$timer.Start()
$form.Add_Shown({ Actualiser-Etat })

[void]$form.ShowDialog()
$timer.Stop()
