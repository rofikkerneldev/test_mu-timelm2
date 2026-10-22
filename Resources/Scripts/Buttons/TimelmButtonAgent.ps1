<#
.SYNOPSIS
  User mode agent for the LG V60 (timelm) hardware buttons.

.DESCRIPTION
  Reads the state of the three physical buttons from TimelmButtons.sys
  (\\.\TimelmButtons) and translates them into Windows input:

      Volume Up            short press            -> TAB
      Volume Down          short press            -> ENTER
      Volume Down          long press (800 ms)    -> Shift+F10 (context menu)
      Power                short press            -> lock the workstation
      Power                long press (1500 ms)   -> shutdown /s (clean shutdown)

  The agent has to run inside the interactive user session, otherwise
  SendInput would be delivered to the wrong session and the lock / shutdown
  would not work.

  The long press detection uses the press duration that the driver reports,
  so it does not depend on the accuracy of the polling loop.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File TimelmButtonAgent.ps1
#>
[CmdletBinding()]
param(
    [string]$LogPath = (Join-Path $env:ProgramData 'Timelm\button-agent.log'),
    [int]$WaitTimeoutMillis = 250,
    [int]$PowerLongPressMillis = 1500,
    [int]$VolumeDownLongPressMillis = 800,
    [switch]$DisableLock,
    [switch]$DisableShutdown,
    [switch]$DryRun,
    [int]$RunSeconds = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1')

$script:LogFile = $LogPath

function Write-TimelmAgentLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    try {
        $directory = Split-Path -Parent $script:LogFile
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch {
        Write-Verbose ('log failed: {0}' -f $_.Exception.Message)
    }
    Write-Verbose $line
}

function Invoke-TimelmKey {
    param(
        [string]$Name,
        [int]$VirtualKey,
        [bool]$Extended = $false
    )
    if ($DryRun) {
        Write-TimelmAgentLog ('action {0} (dry run)' -f $Name)
        return
    }
    [TimelmButtonsNative]::SendKey([uint16]$VirtualKey, $Extended)
    Write-TimelmAgentLog ('action {0}' -f $Name)
}

function Invoke-TimelmShiftF10 {
    if ($DryRun) {
        Write-TimelmAgentLog 'action Shift+F10 (dry run)'
        return
    }
    [TimelmButtonsNative]::SendShiftF10()
    Write-TimelmAgentLog 'action Shift+F10'
}

function Invoke-TimelmLock {
    if ($DisableLock) {
        Write-TimelmAgentLog 'action lock skipped (disabled)'
        return
    }
    if ($DryRun) {
        Write-TimelmAgentLog 'action lock (dry run)'
        return
    }
    $ok = [TimelmButtonsNative]::LockWorkStation()
    Write-TimelmAgentLog ('action lock returned {0}' -f $ok)
}

function Invoke-TimelmShutdown {
    if ($DisableShutdown) {
        Write-TimelmAgentLog 'action shutdown skipped (disabled)'
        return
    }
    if ($DryRun) {
        Write-TimelmAgentLog 'action shutdown /s (dry run)'
        return
    }
    Write-TimelmAgentLog 'action shutdown /s'
    Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s', '/t', '0', '/c', 'TimelmButtons long press' -WindowStyle Hidden
}

$VK_TAB = 0x09
$VK_RETURN = 0x0D

# Button bit -> index inside the driver state arrays (Power, VolumeUp, VolumeDown)
$buttonTable = @(
    [pscustomobject]@{ Bit = 1; Name = 'Power'; Index = 0; LongPress = $PowerLongPressMillis },
    [pscustomobject]@{ Bit = 2; Name = 'VolumeUp'; Index = 1; LongPress = 0 },
    [pscustomobject]@{ Bit = 4; Name = 'VolumeDown'; Index = 2; LongPress = $VolumeDownLongPressMillis }
)

$handle = [IntPtr]::Zero
$down = @{}
$longHandled = @{}
foreach ($button in $buttonTable) {
    $down[$button.Bit] = $false
    $longHandled[$button.Bit] = $false
}

try {
    $deadline = [DateTime]::UtcNow.AddSeconds($RunSeconds)
    $retry = 0

    while ($true) {
        if ($handle -eq [IntPtr]::Zero) {
            try {
                $handle = Open-TimelmButtons
                Write-TimelmAgentLog 'device opened'
            } catch {
                $retry++
                if (($retry % 10) -eq 1) {
                    Write-TimelmAgentLog ('device not available yet: {0}' -f $_.Exception.Message)
                }
                Start-Sleep -Milliseconds 500
                continue
            }
        }

        try {
            $state = Wait-TimelmButtonState -Handle $handle -TimeoutMillis $WaitTimeoutMillis
        } catch {
            Write-TimelmAgentLog ('ioctl failed, closing device: {0}' -f $_.Exception.Message)
            Close-TimelmButtons -Handle $handle
            $handle = [IntPtr]::Zero
            Start-Sleep -Milliseconds 500
            continue
        }

        if ($state.Ready -eq 0) {
            Write-TimelmAgentLog 'driver is not connected to the PMIC yet'
        }

        foreach ($button in $buttonTable) {
            $pressed = ($state.Buttons -band $button.Bit) -ne 0
            $held = [int]$state.HeldMillis[$button.Index]

            if ($pressed -and -not $down[$button.Bit]) {
                $down[$button.Bit] = $true
                $longHandled[$button.Bit] = $false
                Write-TimelmAgentLog ('{0} down' -f $button.Name)

                if ($button.Name -eq 'VolumeUp') {
                    Invoke-TimelmKey -Name 'TAB' -VirtualKey $VK_TAB
                }
            }
            elseif ($pressed -and $down[$button.Bit] -and -not $longHandled[$button.Bit]) {
                if ($button.LongPress -gt 0 -and $held -ge $button.LongPress) {
                    $longHandled[$button.Bit] = $true
                    Write-TimelmAgentLog ('{0} long press ({1} ms)' -f $button.Name, $held)

                    if ($button.Name -eq 'Power') {
                        Invoke-TimelmShutdown
                    }
                    elseif ($button.Name -eq 'VolumeDown') {
                        Invoke-TimelmShiftF10
                    }
                }
            }
            elseif (-not $pressed -and $down[$button.Bit]) {
                $down[$button.Bit] = $false
                Write-TimelmAgentLog ('{0} up after {1} ms' -f $button.Name, $held)

                if (-not $longHandled[$button.Bit]) {
                    if ($button.Name -eq 'Power') {
                        Invoke-TimelmLock
                    }
                    elseif ($button.Name -eq 'VolumeDown') {
                        Invoke-TimelmKey -Name 'ENTER' -VirtualKey $VK_RETURN
                    }
                }
            }
        }

        if ($RunSeconds -gt 0 -and [DateTime]::UtcNow -ge $deadline) {
            Write-TimelmAgentLog 'run time reached, exiting'
            break
        }
    }
}
finally {
    Close-TimelmButtons -Handle $handle
    Write-TimelmAgentLog 'agent stopped'
}
