# SPDX-License-Identifier: BSD-2-Clause-Patent
# Samples the Windows device node list for the identifiers the GPIO touch trial
# cares about and appends one JSON line per sample. The sampler runs as its own
# process, so the timeline survives a trial that aborts, and the file is plain
# text: every sample can be read without a debugger or a trace viewer.
param([Parameter(Mandatory=$true)][string]$Output,
      [int]$Seconds = 60,
      [int]$IntervalMilliseconds = 500,
      [string[]]$Identifiers = @('LGSW4290','TIML0001'))
$ErrorActionPreference = 'Continue'
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60') {throw 'Wrong machine'}
$clauses = @()
foreach ($needle in $Identifiers) {$clauses += "PNPDeviceID LIKE '%"+$needle+"%'"}
$query = 'SELECT PNPDeviceID, ConfigManagerErrorCode, Service, Name FROM Win32_PnPEntity WHERE '+($clauses -join ' OR ')
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
    $row = [ordered]@{utc=[DateTime]::UtcNow.ToString('o');devices=@()}
    try {
        $rows = @(Get-CimInstance -Query $query -ErrorAction SilentlyContinue)
        $devices = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $rows) {
            $devices.Add([ordered]@{id=[string]$item.PNPDeviceID;code=$item.ConfigManagerErrorCode;
                service=[string]$item.Service;name=[string]$item.Name})
        }
        $row.devices = @($devices.ToArray())
    } catch {
        $row.error = $_.Exception.Message
    }
    try {
        Add-Content -LiteralPath $Output -Value ($row | ConvertTo-Json -Depth 5 -Compress)
    } catch {break}
    Start-Sleep -Milliseconds $IntervalMilliseconds
}
