<#
Verify-PilotEvents.ps1 - ONE-TIME pilot diagnostic. NOT part of the deployed package.
Nothing in the script-free build runs this; it exists so the fleet build can stay script-free.

Run it on ONE pilot thin client (normal or elevated PowerShell - System log reads
fine unelevated) BEFORE trusting the values baked into W365-LogoffOnStandbyWake.xml.

It answers the three build-specific questions the trigger query depends on:

  1. What are the numeric Reason codes for "Lid" and "Power Button" on Event 507
     (and 506) on THIS build?  The task XML ships with the community-decoded
     values 15 (Lid) and 1 (Power Button). Confirm them here; if your build
     differs, edit the two numbers in the task XML's Subscription query.

  2. Is DurationInUs present on 507 events, and does it track the real standby
     duration?  Cross-check the StandbySec column against a standby you timed
     yourself (e.g. close the lid for exactly ~3 minutes, reopen, re-run).

  3. How noisy is 507 on this device?  The summary at the end counts exits by
     reason - expect Input Touchpad/Keyboard and AC/DC bursts to dominate and
     Lid / Power Button to be rare. That ratio is the whole case for the filter.

Output: two detail tables (507, then 506 for cross-checking the entering-side
codes) plus a grouped summary for 507.
#>

function Get-PowerEventDetail {
    param([int]$Id)
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = $Id } -MaxEvents 300 -ErrorAction SilentlyContinue |
        ForEach-Object {
            $xml = [xml]$_.ToXml()
            $data = @{}
            foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
            $reasonText = $null
            if ($_.Message -match 'Reason:\s*([^\r\n]+)') { $reasonText = $Matches[1].Trim().TrimEnd('.') }
            [pscustomobject]@{
                Time        = $_.TimeCreated
                Id          = $_.Id
                ReasonCode  = $data['Reason']
                ReasonText  = $reasonText
                StandbySec  = if ($data['DurationInUs']) { [math]::Round(([int64]$data['DurationInUs'] / 1e6), 1) } else { $null }
                HasDuration = [bool]$data['DurationInUs']
            }
        }
}

Write-Host "`n=== Event 507 (exiting Modern Standby) - most recent 300 ===" -ForegroundColor Cyan
$e507 = Get-PowerEventDetail -Id 507
$e507 | Format-Table -AutoSize

Write-Host "`n=== Event 506 (entering Modern Standby) - most recent 300, for code cross-check ===" -ForegroundColor Cyan
$e506 = Get-PowerEventDetail -Id 506
$e506 | Select-Object -First 40 | Format-Table -AutoSize

Write-Host "`n=== 507 summary: exits by reason (code + rendered text) ===" -ForegroundColor Cyan
$e507 | Group-Object ReasonCode, ReasonText | Sort-Object Count -Descending |
    Select-Object Count, Name | Format-Table -AutoSize

$withDur = ($e507 | Where-Object HasDuration).Count
Write-Host "507 events carrying DurationInUs: $withDur / $($e507.Count)" -ForegroundColor Yellow
Write-Host "If ReasonCode for your Lid / Power Button rows is not 15 / 1, update the Subscription query in W365-LogoffOnStandbyWake.xml before importing it." -ForegroundColor Yellow
