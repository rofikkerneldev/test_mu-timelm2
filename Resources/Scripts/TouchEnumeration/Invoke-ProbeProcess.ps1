function Invoke-ProbeProcess {
    param(
        [Parameter(Mandatory=$true)][string]$Executable,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [Parameter(Mandatory=$true)][string]$StdoutPath,
        [Parameter(Mandatory=$true)][string]$StderrPath,
        [int]$TimeoutMs = 600000
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
        if (!$process.WaitForExit($TimeoutMs)) {
            $process.Kill()
            $null = $process.WaitForExit(5000)
            throw 'Collector exceeded its time limit'
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
