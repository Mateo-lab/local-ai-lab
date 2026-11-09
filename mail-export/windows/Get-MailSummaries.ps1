<#
.SYNOPSIS
  Brings the task register and the summaries written by the mail agent (on the AI machine) to this PC and opens them.
  Optionally starts a pass first (lab mail run ...), so one double-click gives "update, then show".

.EXAMPLE
  .\Get-MailSummaries.ps1                      # only fetch what is already there and open the folder
  .\Get-MailSummaries.ps1 -Run registre        # update the register, then fetch
  .\Get-MailSummaries.ps1 -Run planning        # prepare the sprint planning summary, then fetch

  Read direction only: nothing is sent to the AI machine except the fixed command "lab mail run <keyword>".
  Needs the SSH shortcut of the lab (default name "aibeast") and its tunnels or direct address.
  Not tested on a real Windows PC when this was written: try it without -Run first.
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'registre', 'planning', 'synchro')][string]$Run = '',
    [string]$Remote = 'aibeast',
    [string]$RemoteDir = 'Documents/ai-lab/hermes/data/workspace/mail',
    [string]$Dest = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($Dest)) { $Dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AiBeast-Mails' }
New-Item -ItemType Directory -Force $Dest | Out-Null

if ($Run) {
    Write-Host "Running 'lab mail run $Run' on $Remote (this can take several minutes)..." -ForegroundColor Cyan
    # -t: the container needs a terminal. $Run is one of three fixed words (ValidateSet), nothing else is sent.
    & ssh.exe -t $Remote "lab mail run $Run"
    if ($LASTEXITCODE -ne 0) { Write-Host "The pass ended with code $LASTEXITCODE (see the messages above). Fetching what exists anyway." -ForegroundColor Yellow }
}

$ok = $true
foreach ($item in @('taches.md', 'traites.txt', 'resumes', 'brouillons')) {
    & scp.exe -q -r "${Remote}:$RemoteDir/$item" $Dest 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "Not fetched: $item (does not exist yet?)" -ForegroundColor Yellow; $ok = $false }
}
Write-Host "Files in $Dest" -ForegroundColor Green
$latest = Get-ChildItem -Path (Join-Path $Dest 'resumes') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latest) { Start-Process $latest.FullName } elseif (Test-Path (Join-Path $Dest 'taches.md')) { Start-Process (Join-Path $Dest 'taches.md') }
Start-Process explorer.exe $Dest
