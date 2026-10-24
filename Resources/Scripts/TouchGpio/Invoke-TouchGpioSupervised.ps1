# SYSTEM task entry point. The trial worker cannot block this process's clock.
$ErrorActionPreference='Stop'
if($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60'){throw 'Wrong machine'}
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'Phone SYSTEM task identity required'}
if((Get-Content (Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker') -Raw).Trim() -ne 'LG-V60-timelm-8509C01F'){throw 'Wrong installation'}
if(Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'){throw 'Desktop required'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
. (Join-Path $PSScriptRoot 'Invoke-ProbeProcess.ps1')
$null=Get-TouchGpioManifest $PSScriptRoot
$plan=Get-Content (Join-Path $PSScriptRoot 'activation-plan.json') -Raw | ConvertFrom-Json
if($plan.schema -ne 2 -or $plan.mode -notin @('prepare','test') -or $plan.attempt_id -le 0 -or
    $plan.expected_build_id -ne 539365412){throw 'Invalid activation plan'}
$logs=Join-Path $env:SystemDrive 'TimelmLogs\TouchGpioTrial'
$null=New-Item -ItemType Directory -Path $logs -Force
# Never attach another supervisor to an attempt already owned by this boot.
$claim=Join-Path $logs 'supervisor-claim.json'
try{$f=[IO.File]::Open($claim,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}
catch{if(Test-Path $claim){return};throw}
try{
    $bytes=[Text.Encoding]::UTF8.GetBytes((@{attempt_id=$plan.attempt_id;pid=$PID;utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json))
    $f.Write($bytes,0,$bytes.Length);$f.Flush($true)
}finally{$f.Dispose()}
$shutdown={
    $code=Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\shutdown.exe" `
        -Arguments @('/s','/t','30','/c','Timelm touch trial finished or reached its deadline. Reconnect Mu Mass Storage.') `
        -StdoutPath (Join-Path $logs 'shutdown-stdout.txt') -StderrPath (Join-Path $logs 'shutdown-stderr.txt') -TimeoutMs 10000
    if($code -ne 0){throw "Normal shutdown request returned $code"}
}
$state=Invoke-TouchGpioSupervisedWorker -Executable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $PSScriptRoot 'Run-TouchGpioTrial.ps1'),'-Supervised') `
    -StdoutPath (Join-Path $logs 'worker-stdout.txt') -StderrPath (Join-Path $logs 'worker-stderr.txt') `
    -StatePath (Join-Path $logs 'supervisor.json') -AttemptId $plan.attempt_id -TimeoutMs 1500000 -RequestShutdown $shutdown
# The OS shutdown request is issued BEFORE any Task Scheduler cleanup. A
# blocked task API therefore cannot prevent the already scheduled shutdown.
try{
    $task=Get-ScheduledTask -TaskName 'TimelmTouchGpioOnce' -TaskPath '\' -ErrorAction SilentlyContinue
    if($task){
        $exe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $argsExpected='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$PSCommandPath+'"'
        if(@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine $exe -or
            $task.Actions[0].Arguments -cne $argsExpected -or
            $task.Principal.UserId -notin @('SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM')){throw 'Unrelated task; cleanup refused'}
        Unregister-ScheduledTask -TaskName 'TimelmTouchGpioOnce' -TaskPath '\' -Confirm:$false
    }
}catch{
    Write-TouchGpioJson (Join-Path $logs 'task-cleanup-error.json') @{error=$_.Exception.Message;attempt_id=$plan.attempt_id}
}
if(!$state.shutdown_requested){throw 'Normal shutdown request failed; inspect supervisor.json'}
