# Interactive screenshot observer; never installs, restarts or rescans devices.
$ErrorActionPreference='Stop'
if($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60'){throw 'Wrong machine'}
if((Get-Content (Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker') -Raw).Trim() -ne 'LG-V60-timelm-8509C01F'){throw 'Wrong installation'}
if(Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'){throw 'Desktop required'}
if((Get-Process -Id $PID).SessionId -eq 0){throw 'Interactive phone session required'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
. (Join-Path $PSScriptRoot 'Invoke-ProbeProcess.ps1')
$null=Get-TouchGpioManifest $PSScriptRoot
$plan=Get-Content (Join-Path $PSScriptRoot 'activation-plan.json') -Raw | ConvertFrom-Json
if($plan.schema -ne 2 -or $plan.attempt_id -le 0){throw 'Invalid screenshot attempt'}
$logs=Join-Path $env:SystemDrive 'TimelmLogs\TouchGpioTrial';$null=New-Item -ItemType Directory -Path $logs -Force
$phases=New-Object 'System.Collections.Generic.List[object]'
$seen=@{};$timer=[Diagnostics.Stopwatch]::StartNew()
$startup=Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\Timelm-device-manager.cmd'
if((Test-Path $startup) -and (Get-FileHash $startup).Hash -eq (Get-FileHash (Join-Path $PSScriptRoot 'Timelm-device-manager.cmd')).Hash){Remove-Item -LiteralPath $startup}
function Capture-Phase([string]$Phase){
    if($seen.ContainsKey($Phase) -or $seen.Count -ge 6){return}
    $seen[$Phase]=$true
    $entry=[ordered]@{attempt_id=$plan.attempt_id;phase=$Phase;utc=[DateTime]::UtcNow.ToString('o');exit_code=$null;error=$null}
    try{
        $entry.exit_code=Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Capture-TouchGpioDesktop.ps1'),'-Phase',$Phase) `
            -StdoutPath (Join-Path $logs ('capture-'+$Phase+'-out.txt')) -StderrPath (Join-Path $logs ('capture-'+$Phase+'-err.txt')) -TimeoutMs 20000
    }catch{$entry.error=$_.Exception.Message}
    $phases.Add($entry)
    Write-TouchGpioJson (Join-Path $logs 'device-manager-phases.json') @($phases.ToArray())
}
Capture-Phase 'boot'
while($timer.ElapsedMilliseconds -lt 600000){
    $phasePath=Join-Path $logs 'worker-phase.json'
    if(Test-Path $phasePath){
        try{
            $phase=Get-Content $phasePath -Raw | ConvertFrom-Json
            if($phase.attempt_id -eq $plan.attempt_id -and $phase.phase -in @('defer-driver-set','prepare-staged','trial-error','collect-after')){Capture-Phase $phase.phase}
        }catch{}
    }
    if(Test-Path (Join-Path $logs 'trial-error.json')){Capture-Phase 'trial-error'}
    if(Test-Path (Join-Path $logs 'complete.json')){Capture-Phase 'complete';break}
    Start-Sleep -Milliseconds 500
}
