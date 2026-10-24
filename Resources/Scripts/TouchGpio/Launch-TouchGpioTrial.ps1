# Desktop startup bootstrap: one identified phone Administrator -> SYSTEM task.
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60') {throw 'Wrong machine'}
$marker = Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker'
if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') {throw 'Wrong installation'}
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') {throw 'Desktop required'}
$setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
if ($setup.SystemSetupInProgress -ne 0 -or $setup.OOBEInProgress -ne 0) {throw 'Setup incomplete'}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
    !$identity.User.Value.EndsWith('-500')) {throw 'Elevated built-in phone Administrator required'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
$null = Get-TouchGpioManifest $PSScriptRoot
$logs = Join-Path $env:SystemDrive 'TimelmLogs\TouchGpioTrial'
$null = New-Item -ItemType Directory -Path $logs -Force
if (Test-Path -LiteralPath (Join-Path $logs 'attempt.json')) {return}
$receipt = Join-Path $logs 'launch.json'
try {$stream = [IO.File]::Open($receipt,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}
catch {if (Test-Path -LiteralPath $receipt) {return};throw}
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(([ordered]@{phase='launch-attempt';utc=[DateTime]::UtcNow.ToString('o');sid=$identity.User.Value} | ConvertTo-Json))
    $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
} finally {$stream.Dispose()}
$taskName = 'TimelmTouchGpioOnce'
try {
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $script = Join-Path $PSScriptRoot 'Invoke-TouchGpioSupervised.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$script+'"'
    # The phone RTC runs hours behind the PC reference time, and the clock has
    # to be corrected here, before the scheduled task exists. A clock jump
    # while a task with an execution time limit is running makes Task
    # Scheduler compute the task runtime from the new time and hard terminate
    # the action: that ended the first one-boot trial before any hardware step
    # and left neither a completion nor an error receipt behind.
    $hostUtc = [DateTime]::Parse((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'host-utc.txt') -Raw).Trim()).ToUniversalTime()
    $clockBefore = [DateTime]::UtcNow
    $clockAdjusted = $false
    if ([Math]::Abs(($clockBefore - $hostUtc).TotalSeconds) -gt 60) {
        Set-Date -Date $hostUtc.ToLocalTime() | Out-Null
        $clockAdjusted = $true
    }
    $clockAfter = [DateTime]::UtcNow
    if ([Math]::Abs(($clockAfter - $hostUtc).TotalSeconds) -gt 300) {throw 'Phone clock is not within five minutes of the PC reference time'}
    # A task left behind by an interrupted attempt may only be replaced when it
    # is this exact task. An unrelated task that carries the same name is
    # refused and never touched.
    $existing = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    $replacedStaleTask = $false
    if ($existing) {
        # The SYSTEM account is written in several shapes by the task service.
        $systemAccounts = @('SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM')
        $legacyArguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'Run-TouchGpioTrial.ps1')+'"'
        if (@($existing.Actions).Count -ne 1 -or $existing.Actions[0].Execute -ine $exe -or
            $existing.Actions[0].Arguments -cnotin @($arguments,$legacyArguments) -or
            $existing.Principal.UserId -notin $systemAccounts) {throw 'Trial task already exists; refusing to overwrite or rearm it'}
        Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
        $replacedStaleTask = $true
    }
    $action = New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $PSScriptRoot
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # The parent supervisor enforces an 8-minute prepare / 10-minute test deadline independent of
    # a blocked worker cmdlet. The scheduler's two-hour limit is only a backstop.
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 120) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $task = New-ScheduledTask -Action $action -Principal $taskPrincipal -Settings $settings
    $null = Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $task
    $check = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
    if (@($check.Actions).Count -ne 1 -or $check.Actions[0].Execute -ine $exe -or
        $check.Actions[0].Arguments -cne $arguments -or
        $check.Principal.UserId -notin @('SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM')) {throw 'Registered trial task identity mismatch'}
    Start-ScheduledTask -TaskName $taskName -TaskPath '\'
    [ordered]@{phase='system-task-started';utc=[DateTime]::UtcNow.ToString('o');task=$taskName;executable=$exe;arguments=$arguments;
        script_sha256=(Get-FileHash -LiteralPath $script).Hash;execution_limit_minutes=120;
        clock_utc_before=$clockBefore.ToString('o');clock_utc_after=$clockAfter.ToString('o');clock_host_utc=$hostUtc.ToString('o');
        clock_adjusted_by_launcher=$clockAdjusted;replaced_stale_task=$replacedStaleTask} |
        ConvertTo-Json | Set-Content -LiteralPath $receipt
} catch {
    [ordered]@{phase='launch-failed';error=$_.Exception.Message;utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath $receipt
    throw
}
