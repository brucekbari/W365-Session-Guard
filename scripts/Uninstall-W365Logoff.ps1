<#
.SYNOPSIS
  Removes the W365 thin-client logoff package. Run ELEVATED.
  Deletes all four scheduled tasks (including an armed pending logoff)
  and the C:\ProgramData\W365Logoff folder.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
foreach ($t in 'W365-PendingLogoff','W365-LogoffOnWake','W365-ArmLogoffOnDisconnect','W365-CancelLogoffOnReconnect') {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Remove-Item -Path (Join-Path $env:ProgramData 'W365Logoff') -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'W365 logoff package removed.'
