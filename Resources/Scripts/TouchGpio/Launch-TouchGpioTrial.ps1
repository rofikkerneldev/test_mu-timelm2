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
    if (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue) {throw 'Trial task already exists; refusing to overwrite or rearm it'}
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $script = Join-Path $PSScriptRoot 'Run-TouchGpioTrial.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$script+'"'
    $action = New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $PSScriptRoot
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # Five bounded PnP operations, two collectors and the test window can take
    # over 23 minutes in the slow-success case. Keep the final task guard above
    # those bounds so collection and the normal shutdown can still complete.
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $task = New-ScheduledTask -Action $action -Principal $taskPrincipal -Settings $settings
    $null = Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $task
    $check = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
    if (@($check.Actions).Count -ne 1 -or $check.Actions[0].Execute -ine $exe -or
        $check.Actions[0].Arguments -cne $arguments -or $check.Principal.UserId -notin @('SYSTEM','S-1-5-18')) {throw 'Registered trial task identity mismatch'}
    Start-ScheduledTask -TaskName $taskName -TaskPath '\'
    [ordered]@{phase='system-task-started';utc=[DateTime]::UtcNow.ToString('o');task=$taskName;executable=$exe;arguments=$arguments;
        script_sha256=(Get-FileHash -LiteralPath $script).Hash;execution_limit_minutes=30} |
        ConvertTo-Json | Set-Content -LiteralPath $receipt
} catch {
    [ordered]@{phase='launch-failed';error=$_.Exception.Message;utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath $receipt
    throw
}
