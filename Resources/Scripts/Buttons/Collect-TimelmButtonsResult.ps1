<#
.SYNOPSIS
  Collects the result of the button trial from the phone.

.DESCRIPTION
  PC side collection only.  The script reads the log folder of the trial from
  the Windows partition of the identified phone, copies it to a folder on the
  build PC and prints a short summary of what the trial found.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Collect-TimelmButtonsResult.ps1 `
      -Output C:\receipts\buttons-result
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Output
)

$ErrorActionPreference = 'Stop'

if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw 'Run the collection on the x64 PC, not on the phone' }

$disks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.SerialNumber -and $_.SerialNumber.Trim() -eq '8509C01F' })
if ($disks.Count -ne 1 -or $disks[0].Size -ne 126374379520 -or $disks[0].IsBoot -or $disks[0].IsSystem) {
    throw 'V60 USB disk mismatch'
}
$win = Get-Partition -DiskNumber $disks[0].Number -PartitionNumber 30
if ($win.Offset -ne 62719688704 -or $win.Size -ne 42949672960 -or -not $win.DriveLetter) {
    throw 'V60 partition geometry mismatch'
}
$winRoot = [string]$win.DriveLetter + ':\'
$marker = Join-Path $winRoot 'TimelmTools\OobeHelper\timelm-device.marker'
if (-not (Test-Path -LiteralPath $marker)) { throw 'Wrong installed Windows marker' }
if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') { throw 'Wrong installed Windows marker' }

$logs = Join-Path $winRoot 'TimelmLogs\TimelmButtonsTrial'
if (-not (Test-Path -LiteralPath $logs)) { throw 'The trial did not write any log' }

if (-not (Test-Path -LiteralPath $Output -PathType Container)) { throw 'Precreate the PC result directory' }
$outputRoot = (Get-Item -LiteralPath $Output).FullName

$knownReceipts = @(
    'attempt.json', 'agent.log', 'button-state.jsonl', 'certificate.json', 'collect-status.json',
    'complete.json', 'device.json', 'install-buttons-stderr.txt', 'install-buttons-stdout.txt',
    'package.json', 'selected-after.json', 'selected-before.json', 'selected-inf-check.json',
    'service.json', 'setupapi-after-install.log', 'setupapi-before.log', 'setupapi-final.log',
    'shutdown.json', 'trial-error.json', 'trial.log'
)

# A receipt of an earlier attempt must not stay in the folder, otherwise it
# looks like a part of the current one.  Only the names of the trial are
# removed, anything else in the folder stays untouched.
foreach ($name in $knownReceipts) {
    $stale = Join-Path $outputRoot $name
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
}

$copied = foreach ($file in Get-ChildItem -LiteralPath $logs -File) {
    $destination = Join-Path $outputRoot $file.Name
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    $copiedFile = Get-Item -LiteralPath $destination
    [ordered]@{ name = $file.Name; sha256 = (Get-FileHash -LiteralPath $destination).Hash; size = $copiedFile.Length }
}

[ordered]@{
    phase = 'collected'
    utc = [DateTime]::UtcNow.ToString('o')
    serial = '8509C01F'
    source = $logs
    files = $copied
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outputRoot 'collect-status.json')

Write-Host ("Trial result copied to {0}" -f $outputRoot)

foreach ($name in @('trial-error.json', 'complete.json', 'shutdown.json', 'certificate.json', 'selected-inf-check.json', 'device.json')) {
    $path = Join-Path $outputRoot $name
    if (Test-Path -LiteralPath $path) {
        Write-Host ''
        Write-Host ("--- {0} ---" -f $name)
        Get-Content -LiteralPath $path -Raw
    }
}

$trace = Join-Path $outputRoot 'button-state.jsonl'
if (Test-Path -LiteralPath $trace) {
    Write-Host ''
    Write-Host '--- button state changes ---'
    $previous = ''
    foreach ($line in Get-Content -LiteralPath $trace) {
        $entry = $line | ConvertFrom-Json
        $key = '{0}|{1}' -f $entry.buttons, $entry.change_counter
        if ($key -ne $previous) {
            Write-Host ("{0} ready={1} buttons={2} change={3} held={4} presses={5}" -f `
                $entry.utc, $entry.ready, $entry.buttons, $entry.change_counter,
                ($entry.held -join '/'), ($entry.press_count -join '/'))
            $previous = $key
        }
    }
}

$agent = Join-Path $outputRoot 'agent.log'
if (Test-Path -LiteralPath $agent) {
    Write-Host ''
    Write-Host '--- agent log ---'
    Get-Content -LiteralPath $agent
}
