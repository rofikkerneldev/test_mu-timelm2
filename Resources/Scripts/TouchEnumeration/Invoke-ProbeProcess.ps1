function Invoke-ProbeProcess {
    param(
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [Parameter(Mandatory=$true)][string]$StdoutPath,
        [Parameter(Mandatory=$true)][string]$StderrPath,
        [int]$TimeoutMs = 600000,
        [scriptblock]$OnProgress,
        [int]$ProgressIntervalMs = 1000
    )
    $quoted = @($Arguments | ForEach-Object {
        $value = [regex]::Replace($_, '(\\*)"', '$1$1\"')
        $value = [regex]::Replace($value, '(\\+)$', '$1$1')
        '"' + $value + '"'
    })
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = $quoted -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (!$process.Start()) { throw 'Could not launch collector' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $nextProgress=0L
        while(!$process.HasExited) {
            if($timer.ElapsedMilliseconds -ge $TimeoutMs) {
                try{$process.Kill()}catch{}
                $null=$process.WaitForExit(5000)
                throw 'Collector exceeded its time limit'
            }
            if($OnProgress -and $timer.ElapsedMilliseconds -ge $nextProgress) {
                # Diagnostics must never suppress process timeout or shutdown.
                try{$null=& $OnProgress $timer.ElapsedMilliseconds $process.Id}catch{}
                $nextProgress=$timer.ElapsedMilliseconds+[Math]::Max(50,$ProgressIntervalMs)
            }
            $remaining=[Math]::Max(1,$TimeoutMs-[int]$timer.ElapsedMilliseconds)
            $null=$process.WaitForExit([Math]::Min(250,$remaining))
        }
        # Process.Start owns the process handle until Dispose; capture status
        # before disposing instead of refreshing a Start-Process wrapper.
        $exitCode = $process.ExitCode
        # A descendant can inherit a pipe after the direct child exits. Never
        # turn a bounded process wait into an unbounded output-drain wait.
        if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) {throw 'Process output pipes did not close within five seconds'}
        [IO.File]::WriteAllText($StdoutPath, $stdout.Result)
        [IO.File]::WriteAllText($StderrPath, $stderr.Result)
        if ($null -eq $exitCode) { throw 'Process exit status is unavailable' }
        return [int]$exitCode
    } finally {
        $process.Dispose()
    }
}
