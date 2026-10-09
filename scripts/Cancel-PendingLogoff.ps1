<#
.SYNOPSIS
  Cancels an armed pending logoff. Fired by task
  W365-CancelLogoffOnReconnect (LocalSessionManager Event 25).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$log = Join-Path (Join-Path $env:ProgramData 'W365Logoff') 'w365-logoff.log'

if (Get-ScheduledTask -TaskName 'W365-PendingLogoff' -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName 'W365-PendingLogoff' -Confirm:$false -ErrorAction SilentlyContinue
    try {
        Add-Content -Path $log -Value ('{0} [Cancel] user={1} CANCEL: reconnected inside grace window - pending logoff removed, session kept.' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERNAME)
    } catch { }
}
# If nothing was armed, stay silent - reconnects happen all day and the log
# should only record sequences that started with a disconnect.
exit 0
