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
    # The value is always a variable here.  A hashtable literal that is
    # written directly behind the parameter list is turned into a string by
    # the argument parser, so it must never be passed that way.
    $json = $Value | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath (Join-Path $ResultPath $Name) -Value $json -Encoding UTF8
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
    <#
        The driver of a device instance is stored in the instance key of the
        enumeration tree, the class key holds the INF of the driver.  The
        instance key is the one that carries the "Driver" value.
    #>
    $result = [ordered]@{ device = $DeviceId; inf = $null; class_key = $null; instance = $null }
    $enumPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $DeviceId
    if (-not (Test-Path -LiteralPath $enumPath)) { return $result }
    foreach ($instance in @(Get-ChildItem -LiteralPath $enumPath -ErrorAction SilentlyContinue)) {
        $value = Get-ItemProperty -LiteralPath $instance.PSPath -Name 'Driver' -ErrorAction SilentlyContinue
        if (-not $value -or -not $value.Driver) { continue }
        $driver = [string]$value.Driver
        if ($driver -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\\[0-9a-fA-F]{4}$') {
            continue
        }
        $result.class_key = $driver
        $result.instance = $instance.PSChildName
        $inf = Get-ItemPropertyValue -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Control\Class\' + $driver) -Name 'InfPath' -ErrorAction SilentlyContinue
        if ($inf) { $result.inf = [string]$inf }
        break
    }
    return $result
}

function Get-InfHash([string]$InfName) {
    if (-not $InfName) { return $null }
    $path = Join-Path $env:SystemRoot ('INF\' + $InfName)
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
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

function Install-TestCertificate([string]$CerPath) {
    <#
        The driver is signed with the test certificate of the build machine.
        Every CI run creates a new one, so the certificate of this package is
        added to the machine stores before the driver is installed.  Without
        that the driver would not start, Windows would report the unsigned
        image.
    #>
    $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CerPath)
    $result = [ordered]@{
        subject = $certificate.Subject
        thumbprint = $certificate.Thumbprint
        not_after = $certificate.NotAfter.ToString('o')
        added = $false
    }
    foreach ($name in @('Root', 'TrustedPublisher')) {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, 'LocalMachine')
        try {
            $store.Open('ReadWrite')
            $known = $store.Certificates | Where-Object { $_.Thumbprint -eq $certificate.Thumbprint }
            if (-not $known) {
                $store.Add($certificate)
                $result.added = $true
            }
            $store.Close()
        } finally {
            $store.Dispose()
        }
    }
    return $result
}

$agentProcess = $null
$trialError = $null
$installed = $false
$shutdownRequested = $false

# One attempt only.  A second run of the trial is refused, the receipt of the
# first attempt stays untouched.
$attemptFile = Join-Path $ResultPath 'attempt.json'
if (Test-Path -LiteralPath $attemptFile) {
    Write-Log 'an attempt was already made, the trial is not repeated'
    return
}

try {
    $attempt = [ordered]@{
        utc = [DateTime]::UtcNow.ToString('o')
        session = $sessionId
        user = $identity.Name
        package = $PackagePath
        seconds = $Seconds
    }
    Save-Json 'attempt.json' $attempt

    Write-Log ("session {0}, user {1}" -f $sessionId, $identity.Name)

    # The RTC of the phone runs hours behind the build PC.  The reference time
    # is staged with the bundle, the clock is corrected before the first
    # receipt is written, so that the log times can be compared with the PC
    # receipts.  A clock jump is not harmful here, the trial does not use the
    # task scheduler.
    $hostTimeFile = Join-Path $PSScriptRoot 'host-utc.txt'
    if (Test-Path -LiteralPath $hostTimeFile) {
        try {
            $hostUtc = [DateTime]::Parse((Get-Content -LiteralPath $hostTimeFile -Raw).Trim()).ToUniversalTime()
            $clockBefore = [DateTime]::UtcNow
            if ([Math]::Abs(($clockBefore - $hostUtc).TotalSeconds) -gt 60) {
                Set-Date -Date $hostUtc.ToLocalTime() | Out-Null
                Write-Log ("clock corrected, was {0:o} now {1:o}" -f $clockBefore, [DateTime]::UtcNow)
            } else {
                Write-Log ("clock is within a minute of the build PC ({0:o})" -f $clockBefore)
            }
        } catch {
            Write-Log ("the clock could not be compared: {0}" -f $_.Exception.Message)
        }
    }

    $packageInf = Join-Path $PackagePath $infName
    $packageSys = Join-Path $PackagePath $sysName
    if (-not (Test-Path -LiteralPath $packageInf) -or -not (Test-Path -LiteralPath $packageSys)) {
        throw ("Package incomplete in {0}" -f $PackagePath)
    }

    $packageHash = (Get-FileHash -LiteralPath $packageInf -Algorithm SHA256).Hash
    $package = [ordered]@{
        path = $PackagePath
        inf_sha256 = $packageHash
        sys_sha256 = (Get-FileHash -LiteralPath $packageSys -Algorithm SHA256).Hash
        utc = [DateTime]::UtcNow.ToString('o')
    }
    Save-Json 'package.json' $package

    Copy-SetupApiLog 'before'

    # The test certificate of the build machine has to be trusted before the
    # driver is installed, otherwise Windows refuses the image.
    $cerPath = Join-Path $PackagePath 'TimelmButtons.cer'
    if (Test-Path -LiteralPath $cerPath) {
        $certificate = Install-TestCertificate $cerPath
        Save-Json 'certificate.json' $certificate
        Write-Log ("test certificate {0} thumbprint {1} added {2}" -f $certificate.subject, $certificate.thumbprint, $certificate.added)
    } else {
        Write-Log 'the package has no certificate file, the trust of the image is not changed'
    }

    # Only one driver may own the ACPI\KONA1003 hardware id.  The driver that
    # is selected for the device right now is the one that has to go, unless
    # it already is this package.
    $before = Get-SelectedInf $deviceId
    Save-Json 'selected-before.json' $before
    Write-Log ("current driver of {0}: {1} (class {2}, instance {3})" -f $deviceId, $before.inf, $before.class_key, $before.instance)

    $alreadyOurs = ($before.inf -and (Get-InfHash $before.inf) -eq $packageHash)
    if ($alreadyOurs) {
        Write-Log 'the node already uses this package, the driver is not removed'
    } elseif ($before.inf) {
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
    Write-Log ("driver of {0} after the install: {1} (class {2}, instance {3})" -f $deviceId, $after.inf, $after.class_key, $after.instance)

    $actualHash = Get-InfHash $after.inf
    $check = [ordered]@{
        device = $deviceId
        class_key = $after.class_key
        instance = $after.instance
        inf = $after.inf
        sha256 = $actualHash
        expected_sha256 = $packageHash
        matches = ($actualHash -eq $packageHash)
        utc = [DateTime]::UtcNow.ToString('o')
    }
    Save-Json 'selected-inf-check.json' $check
    if ($actualHash -ne $packageHash) {
        throw 'The installed INF of the PMIC node is not the button driver'
    }

    $device = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'ACPI\KONA1003*' } | Select-Object -First 1
    if ($device) {
        $deviceRecord = [ordered]@{
            pnp_device_id = $device.PNPDeviceID
            name = $device.Name
            status = $device.Status
            config_manager_error_code = $device.ConfigManagerErrorCode
            service = $device.Service
            utc = [DateTime]::UtcNow.ToString('o')
        }
        Save-Json 'device.json' $deviceRecord
        Write-Log ("device status {0}, problem code {1}, service {2}" -f $device.Status, $device.ConfigManagerErrorCode, $device.Service)
    }

    $service = Get-CimInstance Win32_SystemDriver -Filter "Name='TimelmButtons'" -ErrorAction SilentlyContinue
    if ($service) {
        $serviceRecord = [ordered]@{
            name = $service.Name
            state = $service.State
            start_mode = $service.StartMode
            path = $service.PathName
            utc = [DateTime]::UtcNow.ToString('o')
        }
        Save-Json 'service.json' $serviceRecord
        Write-Log ("service state {0}, start mode {1}" -f $service.State, $service.StartMode)
    } else {
        Write-Log 'the driver service was not found'
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
        Write-Log 'the control device is open'
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

    $complete = [ordered]@{
        error = $trialError
        seconds = $Seconds
        normal_shutdown = $true
        utc = [DateTime]::UtcNow.ToString('o')
    }
    Save-Json 'complete.json' $complete
}
catch {
    $trialError = $_.Exception.Message
    Write-Log ("trial failed: {0}" -f $trialError)
    $errorRecord = [ordered]@{
        error = $trialError
        utc = [DateTime]::UtcNow.ToString('o')
    }
    Save-Json 'trial-error.json' $errorRecord
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

    # The Startup entry is disarmed after the attempt, so that the trial does
    # not run again on the next boot.  Only an entry that is byte for byte the
    # staged one may be removed.
    try {
        $startup = Join-Path $env:SystemDrive 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Timelm-buttons.cmd'
        $staged = Join-Path $PSScriptRoot 'Timelm-buttons.cmd'
        if ((Test-Path -LiteralPath $startup) -and (Test-Path -LiteralPath $staged)) {
            if ((Get-FileHash -LiteralPath $startup -Algorithm SHA256).Hash -eq
                (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash) {
                Remove-Item -LiteralPath $startup -Force
                Write-Log 'the startup entry of this trial was removed'
            } else {
                Write-Log 'the startup entry does not belong to this trial, it stays'
            }
        }
    } catch {
        Write-Log ("removing the startup entry failed: {0}" -f $_.Exception.Message)
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
    $shutdown = [ordered]@{
        requested = $shutdownRequested
        utc = [DateTime]::UtcNow.ToString('o')
    }
    Save-Json 'shutdown.json' $shutdown
}

if ($trialError) {
    throw $trialError
}
