<#
.SYNOPSIS
  Installs the W365 thin-client logoff package. Run ELEVATED (SYSTEM via
  Intune). Copies scripts to C:\ProgramData\W365Logoff\scripts, locks down
  script ACLs, creates the log file, and imports the three scheduled tasks.
.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File Install-W365Logoff.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:ProgramData 'W365Logoff'
$destScripts = Join-Path $dest 'scripts'
$taskSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'tasks'
if (-not (Test-Path $taskSource)) { $taskSource = Join-Path $PSScriptRoot 'tasks' }

New-Item -ItemType Directory -Path $destScripts -Force | Out-Null

foreach ($f in 'Invoke-W365Logoff.ps1','Arm-PendingLogoff.ps1','Cancel-PendingLogoff.ps1','config.json') {
    Copy-Item -Path (Join-Path $PSScriptRoot $f) -Destination (Join-Path $destScripts $f) -Force
}

# Log file: create it now so the ACL below can let Users append to the log
# while the scripts themselves stay read/execute-only for Users.
$log = Join-Path $dest 'w365-logoff.log'
if (-not (Test-Path $log)) { New-Item -ItemType File -Path $log | Out-Null }
& icacls.exe $log /grant '*S-1-5-32-545:(M)' | Out-Null   # BUILTIN\Users: Modify (log only)
& icacls.exe $destScripts /inheritance:r /grant '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

foreach ($t in 'W365-LogoffOnWake','W365-ArmLogoffOnDisconnect','W365-CancelLogoffOnReconnect') {
    $xml = Join-Path $taskSource "$t.xml"
    if (-not (Test-Path $xml)) { throw "Task XML not found: $xml" }
    & schtasks.exe /create /tn $t /xml $xml /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks import failed for $t (exit $LASTEXITCODE)" }
}

Add-Content -Path $log -Value ('{0} [Install] package installed by {1}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERNAME)
Write-Output 'W365 logoff package installed: 3 tasks imported, scripts in C:\ProgramData\W365Logoff\scripts.'
