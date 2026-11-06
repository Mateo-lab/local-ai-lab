<#
.SYNOPSIS
  Registers (or removes) the daily Windows scheduled task that runs Export-Outlook.ps1. Current user, no admin rights.

.DESCRIPTION
  The task runs ONLY while you are logged on (Outlook automation needs your interactive session), at -At every
  day, and also 3 minutes after each logon. "Run as soon as possible after a missed start" is on, so a PC that was
  off at the scheduled time catches up at the next start; the script itself skips a scheduled run when one
  succeeded less than minIntervalHours ago. If the run fails (Outlook or VPN not ready), Windows retries every
  30 minutes, up to 6 times. Time limit 30 minutes.

  Usage:  powershell -ExecutionPolicy Bypass -File .\Install-MailExportTask.ps1 -At 07:30
          powershell -ExecutionPolicy Bypass -File .\Install-MailExportTask.ps1 -Remove
  Equivalent without this script:  schtasks /Create /TN "MailExport\OutlookDaily" /XML task.xml /F
  A group policy of your company may forbid creating tasks: the script then says so and changes nothing.
#>
[CmdletBinding()]
param(
    [string]$At = '07:30',
    [string]$Name = 'MailExport\OutlookDaily',
    [string]$Script = '',
    [string]$Config = '',
    [switch]$Remove,
    [switch]$PrintXml
)
# $PSScriptRoot can be empty in a param() default on Windows PowerShell 5.1: resolve the script folder here instead.
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir) -and $MyInvocation.MyCommand.Path) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = (Get-Location).Path }
if ([string]::IsNullOrEmpty($Script)) { $Script = Join-Path $ScriptDir 'Export-Outlook.ps1' }
if ([string]::IsNullOrEmpty($Config)) { $Config = Join-Path $ScriptDir 'export-outlook.config.json' }
$ErrorActionPreference = 'Stop'
if ($Remove) {
    & schtasks.exe /Delete /TN $Name /F
    exit $LASTEXITCODE
}
if ($At -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Write-Host "Invalid -At '$At' (expected HH:mm)." -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $Script)) { Write-Host "Script not found: $Script" -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $Config)) { Write-Host "Configuration not found: $Config (copy export-outlook.config.example.json and edit it first)." -ForegroundColor Red; exit 1 }
$esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
$args1 = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Config "{1}" -Scheduled' -f $Script, $Config
$start = '{0}T{1}:00' -f (Get-Date).ToString('yyyy-MM-dd'), $At
$me = & $esc ([Security.Principal.WindowsIdentity]::GetCurrent().Name)     # DOMAIN\user: the logon trigger must be YOURS only
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Daily export of Outlook mails to the AI machine (Export-Outlook.ps1)</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$me</UserId>
      <Delay>PT3M</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$me</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowHardTerminate>true</AllowHardTerminate>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <RestartOnFailure><Interval>PT30M</Interval><Count>6</Count></RestartOnFailure>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$(& $esc $args1)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
if ($PrintXml) { $xml; exit 0 }
$tmp = Join-Path $env:TEMP 'mail-export-task.xml'
[IO.File]::WriteAllText($tmp, $xml, [System.Text.Encoding]::Unicode)     # schtasks expects UTF-16
try { & schtasks.exe /Create /TN $Name /XML $tmp /F; $rc = $LASTEXITCODE } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
if ($rc -ne 0) { Write-Host "schtasks failed (code $rc). Your company may restrict task creation." -ForegroundColor Red; exit $rc }
Write-Host "Task '$Name' registered: daily at $At and 3 min after logon." -ForegroundColor Green
Write-Host "Check:  schtasks /Query /TN $Name /V /FO LIST      Run now:  schtasks /Run /TN $Name"
Write-Host "Status of the last export:  powershell -ExecutionPolicy Bypass -File `"$Script`" -Config `"$Config`" -Status"
