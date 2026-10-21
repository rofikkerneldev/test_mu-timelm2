$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60') {
    throw 'This probe is for the ARM64 V60 installation only'
}
$marker = Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker'
if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') {
    throw 'Installation marker mismatch'
}
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') { throw 'Run in Windows desktop' }
$setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
if ($setup.SystemSetupInProgress -ne 0 -or $setup.OOBEInProgress -ne 0) { throw 'Setup is not complete' }
$logs = Join-Path $env:SystemDrive 'TimelmLogs\TouchEnumerationProbe'
$null = New-Item -ItemType Directory -Path $logs -Force
if (Test-Path -LiteralPath (Join-Path $logs 'attempt.json')) { return }
# One attempt only, including failures; no repeating boot-time collector.
[ordered]@{started=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $logs 'attempt.json')
$startup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\Timelm-touch-enumeration.cmd'
$expected = Join-Path $PSScriptRoot 'Timelm-touch-enumeration.cmd'
if ((Test-Path -LiteralPath $startup) -and
    (Get-FileHash -LiteralPath $startup).Hash -eq (Get-FileHash -LiteralPath $expected).Hash) {
    Remove-Item -LiteralPath $startup
}
try {
    . (Join-Path $PSScriptRoot 'Invoke-ProbeProcess.ps1')
    Start-Sleep -Seconds 30
    $collector = Join-Path $PSScriptRoot 'Collect-TimelmDiagnostics.ps1'
    $exitCode = Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$collector,'-SkipEsp','-OutputRoot',$logs) `
        -StdoutPath (Join-Path $logs 'collector-output.txt') -StderrPath (Join-Path $logs 'collector-error.txt')
    if ($exitCode -ne 0) { throw "Collector failed: $exitCode" }
    $results = @(Get-ChildItem -LiteralPath $logs -Filter collection-status.json -File -Recurse)
    if ($results.Count -ne 1) { throw 'Collector did not produce its completion receipt' }
    [ordered]@{phase='collected';utc=[DateTime]::UtcNow.ToString('o');result=$results[0].FullName;
        next_action='normal shutdown for offline log retrieval'} | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $logs 'complete.json')
    & "$env:SystemRoot\System32\shutdown.exe" /s /t 30 /c 'Timelm touch diagnostics saved. Shutdown for log retrieval.'
    if ($LASTEXITCODE -ne 0) { throw 'Automatic shutdown could not be requested' }
} catch {
    [ordered]@{phase='failed';error=$_.Exception.Message;utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logs 'failed.json')
}
