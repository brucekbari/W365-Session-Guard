<#
.SYNOPSIS
  Logs off the current user's local session. Used for both the wake path
  (-Mode Wake, immediate) and the pending-logoff task (-Mode Expired).
.NOTES
  Runs in the logged-on user's context (InteractiveToken scheduled task).
  Resolves its OWN session id from its own process - never queries by
  username - so it cannot log off the wrong session.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Wake', 'Expired')]
    [string]$Mode
)

$ErrorActionPreference = 'Continue'
$base = Join-Path $env:ProgramData 'W365Logoff'
$log  = Join-Path $base 'w365-logoff.log'

function Write-Log([string]$Message) {
    try {
        $line = '{0} [{1}] user={2} session={3} {4}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mode, $env:USERNAME, `
            [System.Diagnostics.Process]::GetCurrentProcess().SessionId, $Message
        Add-Content -Path $log -Value $line -ErrorAction Stop
    } catch { }
}

# A wake/expired logoff makes any armed pending logoff moot.
try { Unregister-ScheduledTask -TaskName 'W365-PendingLogoff' -Confirm:$false -ErrorAction SilentlyContinue } catch { }

$sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
if ($sessionId -le 0) {
    Write-Log 'ABORT: running in session 0 (not a user session) - not logging off.'
    exit 1
}

if ($Mode -eq 'Wake') {
    # Give the OS / event log a moment to settle after resume before the
    # session is torn down. Configurable via config.json (WakeDelaySeconds).
    $delay = 3
    try {
        $cfg = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
        if ($cfg.WakeDelaySeconds -ge 0) { $delay = [int]$cfg.WakeDelaySeconds }
    } catch { }
    if ($delay -gt 0) { Start-Sleep -Seconds $delay }
}

Write-Log 'LOGOFF: logging off own session now.'
& "$env:SystemRoot\System32\logoff.exe" $sessionId
