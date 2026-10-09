<#
.SYNOPSIS
  Arms a one-time pending logoff at now + GraceMinutes (config.json, default 5).
  Fired by task W365-ArmLogoffOnDisconnect (LocalSessionManager Event 24).
.NOTES
  If a pending logoff is already armed it is left alone - repeated
  disconnect flapping must not keep pushing the logoff time out.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$base = Join-Path $env:ProgramData 'W365Logoff'
$log  = Join-Path $base 'w365-logoff.log'

function Write-Log([string]$Message) {
    try {
        Add-Content -Path $log -Value ('{0} [Arm] user={1} {2}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERNAME, $Message) -ErrorAction Stop
    } catch { }
}

if (Get-ScheduledTask -TaskName 'W365-PendingLogoff' -ErrorAction SilentlyContinue) {
    Write-Log 'ARM skipped: a pending logoff is already armed (timer not reset).'
    exit 0
}

$grace = 5
try {
    $cfg = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
    if ($cfg.GraceMinutes -ge 1) { $grace = [int]$cfg.GraceMinutes }
} catch { }

$runAt  = (Get-Date).AddMinutes($grace)
$script = Join-Path $PSScriptRoot 'Invoke-W365Logoff.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Mode Expired"
$trigger = New-ScheduledTaskTrigger -Once -At $runAt
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName 'W365-PendingLogoff' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Log ("ARM: pending logoff registered for {0} ({1} min grace)." -f $runAt.ToString('HH:mm:ss'), $grace)
