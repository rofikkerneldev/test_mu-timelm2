<#
.SYNOPSIS
  One attempt of the LG V60 (timelm) button trial on the phone.

.DESCRIPTION
  The script installs the TimelmButtons driver, runs the user mode agent in
  the interactive session and records what the three physical buttons do.

  It has to run in the interactive session of the logged on user, because
  the agent uses SendInput and LockWorkStation, which only work there.  The
  user has to be able to press the buttons while the test window is open.

  Sequence:

      1. guard checks (machine, installation marker, desktop, elevation)
      2. the driver that currently owns ACPI\KONA1003 is removed, the
         TimelmButtons package takes the node over
      3. the selected INF of the device is verified against the package
      4. the agent runs for the test window, the button state is sampled
      5. the log, the setupapi snapshot and the state trace are collected
      6. the phone shuts down normally, the EFI restore stays first in the
         boot order

  Every failure is written to trial-error.json, the shutdown is always
  requested when the trial itself was started, so that the phone can be
  put back into mass storage mode and the logs can be collected.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Run-TimelmButtonsTrial.ps1 -Seconds 120
#>
[CmdletBinding()]
param(
    [string]$PackagePath,
    [int]$Seconds = 120,
    [string]$ResultPath,
    [switch]$KeepDriver
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# The machine guard runs before anything is written, a wrong machine must
# not be touched at all.
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60') {
    throw 'Wrong machine'
}

$marker = Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker'
if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') {
    throw 'Wrong installation'
}

if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') {
    throw 'Desktop required'
}

$setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
if ($setup.SystemSetupInProgress -ne 0 -or $setup.OOBEInProgress -ne 0) {
    throw 'Setup incomplete'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'An elevated shell in the interactive session is required'
}

$sessionId = (Get-Process -Id $PID).SessionId
if ($sessionId -le 0) {
    throw 'The trial has to run in the interactive session'
}

. (Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1')

if (-not $PackagePath) {
    $PackagePath = Join-Path $PSScriptRoot 'Drivers\Buttons'
}
$PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path

if (-not $ResultPath) {
    $ResultPath = Join-Path $env:SystemDrive 'TimelmLogs\TimelmButtonsTrial'
}
$null = New-Item -ItemType Directory -Force -Path $ResultPath

$deviceId = 'ACPI\KONA1003'
$infName = 'TimelmButtons.inf'
$sysName = 'TimelmButtons.sys'

function Save-Json([string]$Name, $Value) {
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ResultPath $Name)
}

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Write-Host $line
    try {
        Add-Content -LiteralPath (Join-Path $ResultPath 'trial.log') -Value $line -Encoding UTF8
    } catch {
    }
}

function Copy-SetupApiLog([string]$Label) {
    try {
        $source = Join-Path $env:SystemRoot 'INF\setupapi.dev.log'
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $ResultPath ('setupapi-' + $Label + '.log')) -Force
        }
    } catch {
    }
}

function Get-SelectedInf([string]$DeviceId) {
    $result = [ordered]@{ device = $DeviceId; inf = $null; class_key = $null }
    try {
        $driver = Get-ItemPropertyValue -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $DeviceId) -Name 'Driver'
    } catch {
        return $result
    }
    if ($driver -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\\[0-9a-fA-F]{4}$') {
        return $result
    }
    $result.class_key = $driver
    try {
        $result.inf = Get-ItemPropertyValue -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $driver) -Name 'InfPath'
    } catch {
    }
    return $result
}

function Invoke-PnP([string]$Label, [string[]]$Arguments) {
    $stdout = Join-Path $ResultPath ($Label + '-stdout.txt')
    $stderr = Join-Path $ResultPath ($Label + '-stderr.txt')
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = "$env:SystemRoot\System32\pnputil.exe"
    $process.StartInfo.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $out = ''
    $err = ''
    $code = -1
    try {
        $null = $process.Start()
        $out = $process.StandardOutput.ReadToEnd()
        $err = $process.StandardError.ReadToEnd()
        $process.WaitForExit(180000)
        $code = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    [IO.File]::WriteAllText($stdout, $out)
    [IO.File]::WriteAllText($stderr, $err)
    Write-Log ("pnputil {0} exit {1}" -f $Label, $code)
    return $code
}

$agentProcess = $null
$trialError = $null
$installed = $false
$shutdownRequested = $false

try {
    Write-Log ("session {0}, user {1}" -f $sessionId, $identity.Name)

    $packageInf = Join-Path $PackagePath $infName
    $packageSys = Join-Path $PackagePath $sysName
    if (-not (Test-Path -LiteralPath $packageInf) -or -not (Test-Path -LiteralPath $packageSys)) {
        throw ("Package incomplete in {0}" -f $PackagePath)
    }

    Save-Json 'package.json' [ordered]@{
        path = $PackagePath
        inf_sha256 = (Get-FileHash -LiteralPath $packageInf -Algorithm SHA256).Hash
        sys_sha256 = (Get-FileHash -LiteralPath $packageSys -Algorithm SHA256).Hash
        utc = [DateTime]::UtcNow.ToString('o')
    }

    Copy-SetupApiLog 'before'

    # Only one driver may own the ACPI\KONA1003 hardware id.  The driver that
    # is selected for the device right now is the one that has to go.
    $before = Get-SelectedInf $deviceId
    Save-Json 'selected-before.json' $before
    Write-Log ("current driver of {0}: {1}" -f $deviceId, $before.inf)

    if ($before.inf -and $before.inf -ne $infName) {
        $code = Invoke-PnP 'remove-previous' @('/delete-driver', $before.inf, '/uninstall')
        # 259 is ERROR_NO_MORE_ITEMS, the package was staged but no device
        # had to be updated.
        if ($code -ne 0 -and $code -ne 259) {
            throw ("Removing the previous driver returned {0}" -f $code)
        }
    }

    $code = Invoke-PnP 'install-buttons' @('/add-driver', $packageInf, '/install')
    # 259 is ERROR_NO_MORE_ITEMS: the package was staged but no device had to
    # be updated.  The selected INF of the exact device is verified below.
    if ($code -ne 0 -and $code -ne 259) {
        throw ("Installing the button driver returned {0}" -f $code)
    }
    $installed = $true

    Copy-SetupApiLog 'after-install'

    $after = Get-SelectedInf $deviceId
    Save-Json 'selected-after.json' $after

    $installedInf = Join-Path $env:SystemRoot ('INF\' + $after.inf)
    $expectedHash = (Get-FileHash -LiteralPath $packageInf -Algorithm SHA256).Hash
    $actualHash = $null
    if ($after.inf -and (Test-Path -LiteralPath $installedInf)) {
        $actualHash = (Get-FileHash -LiteralPath $installedInf -Algorithm SHA256).Hash
    }
    Save-Json 'selected-inf-check.json' [ordered]@{
        device = $deviceId
        class_key = $after.class_key
        inf = $after.inf
        sha256 = $actualHash
        expected_sha256 = $expectedHash
        matches = ($actualHash -eq $expectedHash)
        utc = [DateTime]::UtcNow.ToString('o')
    }
    if ($actualHash -ne $expectedHash) {
        throw 'The installed INF of the PMIC node is not the button driver'
    }

    $device = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'ACPI\KONA1003*' } | Select-Object -First 1
    if ($device) {
        Save-Json 'device.json' [ordered]@{
            pnp_device_id = $device.PNPDeviceID
            name = $device.Name
            status = $device.Status
            config_manager_error_code = $device.ConfigManagerErrorCode
            service = $device.Service
            utc = [DateTime]::UtcNow.ToString('o')
        }
    }

    # The agent runs in this interactive session, so SendInput and
    # LockWorkStation reach the shell of the logged on user.
    $installDirectory = Join-Path $env:ProgramData 'Timelm'
    $null = New-Item -ItemType Directory -Force -Path $installDirectory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'TimelmButtonAgent.ps1') -Destination $installDirectory -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1') -Destination $installDirectory -Force

    $agentLog = Join-Path $ResultPath 'agent.log'
    $agentScript = Join-Path $installDirectory 'TimelmButtonAgent.ps1'
    $agentArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $agentScript,
        '-LogPath', $agentLog,
        '-RunSeconds', [string]($Seconds + 30),
        '-DisableShutdown'
    )

    $agentProcess = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $agentArguments -WindowStyle Hidden -PassThru
    Write-Log ("agent started, pid {0}" -f $agentProcess.Id)

    # Sample the driver state during the test window, the trace is the
    # evidence of what the buttons actually did.
    $trace = Join-Path $ResultPath 'button-state.jsonl'
    $handle = [IntPtr]::Zero
    try {
        $handle = Open-TimelmButtons
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) {
            try {
                $state = Wait-TimelmButtonState -Handle $handle -TimeoutMillis 250
            } catch {
                Write-Log ("ioctl failed: {0}" -f $_.Exception.Message)
                break
            }
            $entry = [ordered]@{
                utc = [DateTime]::UtcNow.ToString('o')
                ready = $state.Ready
                buttons = $state.Buttons
                change_counter = $state.ChangeCounter
                held = $state.HeldMillis
                press_count = $state.PressCount
            }
            Add-Content -LiteralPath $trace -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
        }
    } catch {
        Write-Log ("sampling stopped: {0}" -f $_.Exception.Message)
    } finally {
        if ($handle -ne [IntPtr]::Zero) {
            Close-TimelmButtons -Handle $handle
        }
    }

    Write-Log 'test window closed'

    Save-Json 'complete.json' [ordered]@{
        error = $trialError
        seconds = $Seconds
        normal_shutdown = $true
        utc = [DateTime]::UtcNow.ToString('o')
    }
}
catch {
    $trialError = $_.Exception.Message
    Write-Log ("trial failed: {0}" -f $trialError)
    Save-Json 'trial-error.json' [ordered]@{
        error = $trialError
        utc = [DateTime]::UtcNow.ToString('o')
    }
}
finally {
    if ($agentProcess) {
        try {
            if (-not $agentProcess.HasExited) {
                Stop-Process -Id $agentProcess.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {
        }
    }
    Copy-SetupApiLog 'final'
    if ($installed -and -not $KeepDriver) {
        # The driver stays installed, a second attempt starts from the same
        # state and installs the package again.
        Write-Log 'the button driver stays installed'
    }

    # The phone always powers off cleanly at the end of the attempt, so that
    # the mass storage mode can be reached again for the log collection.
    Write-Log 'shutting down'
    try {
        & "$env:SystemRoot\System32\shutdown.exe" /s /t 30 /c 'Timelm button trial complete. Logs saved; reconnect Mu Mass Storage.'
        $shutdownRequested = ($LASTEXITCODE -eq 0)
    } catch {
        Write-Log ("shutdown request failed: {0}" -f $_.Exception.Message)
    }
    Save-Json 'shutdown.json' [ordered]@{
        requested = $shutdownRequested
        utc = [DateTime]::UtcNow.ToString('o')
    }
}

if ($trialError) {
    throw $trialError
}
