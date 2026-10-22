<#
.SYNOPSIS
  User mode agent for the LG V60 (timelm) hardware buttons.

.DESCRIPTION
  Reads the state of the three physical buttons from TimelmButtons.sys
  (\\.\TimelmButtons) and translates them into Windows input.

  What happens with a button is decided by the mapping of the driver, so
  the behaviour can be changed at run time without a new build:

      Volume Up            short press            -> TAB
      Volume Down          short press            -> ENTER
      Volume Down          long press (800 ms)    -> Shift+F10 (context menu)
      Power                short press            -> lock the workstation,
                                                   wake the display when
                                                   the session is locked
      Power                long press (1500 ms)   -> shutdown /s (clean shutdown)
      Assist               short press            -> the program of the
                                                   target file (or the start
                                                   menu)

  With the mapping in the mode "Hid" the short press is not answered by the
  agent at all.  The driver then reports the button to Windows as a real
  HID key, so that the volume keys change the volume and the power key
  opens the power menu of Windows.  Only the long press is left to the
  agent.

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
    [string]$AssistTargetPath = (Join-Path $env:ProgramData 'Timelm\assist-target.txt'),
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

function Invoke-TimelmWake {
    <# Turns the display on again and wakes the system out of the standby. #>
    if ($DryRun) {
        Write-TimelmAgentLog 'action wake (dry run)'
        return
    }

    $locked = Test-TimelmWorkstationLocked
    $result = Invoke-TimelmWakeDisplay
    Write-TimelmAgentLog ('action wake (locked {0}, previous state 0x{1:X}, nudge {2})' -f $locked, $result.PreviousState, $result.NudgeResult)
}

function Invoke-TimelmLockOrWake {
    <#
      Locks the workstation when it is unlocked and wakes the display when
      the session is locked.  That is the behaviour of the power key of a
      phone.
    #>
    if (Test-TimelmWorkstationLocked) {
        Invoke-TimelmWake
        return
    }

    Invoke-TimelmLock
}

function Invoke-TimelmStartMenu {
    <# The Windows key opens the start menu of Windows. #>
    if ($DryRun) {
        Write-TimelmAgentLog 'action start menu (dry run)'
        return
    }
    [TimelmButtonsNative]::SendKey([uint16]0x5B, $true)
    Write-TimelmAgentLog 'action start menu'
}

function Invoke-TimelmLaunchTarget {
    <#
      Starts the program of the target file.  That is the way to direct the
      assist key to another function.  Without the file the agent only
      writes a note into its log.
    #>
    if ($DryRun) {
        Write-TimelmAgentLog 'action assist target (dry run)'
        return
    }

    $target = $null
    if (Test-Path -LiteralPath $AssistTargetPath) {
        $target = (Get-Content -LiteralPath $AssistTargetPath -Raw).Trim()
    }

    if (-not $target) {
        Write-TimelmAgentLog ('action assist target skipped (no target in {0})' -f $AssistTargetPath)
        return
    }

    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', $target -WindowStyle Hidden
    Write-TimelmAgentLog ('action assist target started: {0}' -f $target)
}

$script:TimelmVkTab = 0x09
$script:TimelmVkReturn = 0x0D

#
# Performs one action of the mapping.
#
function Invoke-TimelmAgentAction {
    param([int]$Action)

    if ($Action -eq $script:TimelmAgentAction.Tab) {
        Invoke-TimelmKey -Name 'TAB' -VirtualKey $script:TimelmVkTab
    }
    elseif ($Action -eq $script:TimelmAgentAction.Enter) {
        Invoke-TimelmKey -Name 'ENTER' -VirtualKey $script:TimelmVkReturn
    }
    elseif ($Action -eq $script:TimelmAgentAction.ShiftF10) {
        Invoke-TimelmShiftF10
    }
    elseif ($Action -eq $script:TimelmAgentAction.Lock) {
        Invoke-TimelmLock
    }
    elseif ($Action -eq $script:TimelmAgentAction.Shutdown) {
        Invoke-TimelmShutdown
    }
    elseif ($Action -eq $script:TimelmAgentAction.Wake) {
        Invoke-TimelmWake
    }
    elseif ($Action -eq $script:TimelmAgentAction.LockOrWake) {
        Invoke-TimelmLockOrWake
    }
    elseif ($Action -eq $script:TimelmAgentAction.LaunchTarget) {
        Invoke-TimelmLaunchTarget
    }
    elseif ($Action -eq $script:TimelmAgentAction.StartMenu) {
        Invoke-TimelmStartMenu
    }
}

# Button bit -> index inside the driver state arrays (Power, VolumeUp, VolumeDown, Assist)
#
# The values are the fallback for a driver of the first version, which does
# not know the mapping.  As soon as the mapping of the driver is readable,
# it decides what the agent does.
$buttonTable = @(
    [pscustomobject]@{ Bit = 1; Name = 'Power'; Index = 0; LongPress = $PowerLongPressMillis; ShortAction = $script:TimelmAgentAction.LockOrWake; LongAction = $script:TimelmAgentAction.Shutdown },
    [pscustomobject]@{ Bit = 2; Name = 'VolumeUp'; Index = 1; LongPress = 0; ShortAction = $script:TimelmAgentAction.Tab; LongAction = $script:TimelmAgentAction.None },
    [pscustomobject]@{ Bit = 4; Name = 'VolumeDown'; Index = 2; LongPress = $VolumeDownLongPressMillis; ShortAction = $script:TimelmAgentAction.Enter; LongAction = $script:TimelmAgentAction.ShiftF10 },
    [pscustomobject]@{ Bit = 8; Name = 'Assist'; Index = 3; LongPress = 0; ShortAction = $script:TimelmAgentAction.LaunchTarget; LongAction = $script:TimelmAgentAction.None }
)

$handle = [IntPtr]::Zero
$down = @{}
$longHandled = @{}
$mappingLoaded = $false
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

        if (-not $mappingLoaded) {
            $mappingLoaded = $true
            try {
                $mapping = Get-TimelmButtonMapping -Handle $handle
                if ($mapping.Version -ge 2 -and $mapping.Action.Count -ge 3) {
                    foreach ($button in $buttonTable) {
                        if ($button.Index -ge $mapping.Action.Count) { continue }
                        $action = $mapping.Action[$button.Index]
                        $button.LongPress = [int]$action.LongPressMillis
                        $button.ShortAction = [int]$action.AgentShortAction
                        $button.LongAction = [int]$action.AgentLongAction
                    }
                    Write-TimelmAgentLog ('mapping version {0} with {1} actions is used by the agent' -f $mapping.Version, $mapping.Action.Count)
                } else {
                    Write-TimelmAgentLog ('the driver has the mapping version {0}, the built in behaviour is used' -f $mapping.Version)
                }
            } catch {
                Write-TimelmAgentLog ('the mapping could not be read: {0}' -f $_.Exception.Message)
            }
        }

        try {
            $state = Wait-TimelmButtonState -Handle $handle -TimeoutMillis $WaitTimeoutMillis
        } catch {
            Write-TimelmAgentLog ('ioctl failed, closing device: {0}' -f $_.Exception.Message)
            Close-TimelmButtons -Handle $handle
            $handle = [IntPtr]::Zero
            $mappingLoaded = $false
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

                #
                # A button without a long press answers at once, a button
                # with a long press has to wait for the release, otherwise
                # the long press would answer twice.
                #
                if ($button.LongPress -le 0 -and $button.ShortAction -ne 0) {
                    Invoke-TimelmAgentAction $button.ShortAction
                }
            }
            elseif ($pressed -and $down[$button.Bit] -and -not $longHandled[$button.Bit]) {
                if ($button.LongPress -gt 0 -and $held -ge $button.LongPress) {
                    $longHandled[$button.Bit] = $true
                    Write-TimelmAgentLog ('{0} long press ({1} ms)' -f $button.Name, $held)
                    Invoke-TimelmAgentAction $button.LongAction
                }
            }
            elseif (-not $pressed -and $down[$button.Bit]) {
                $down[$button.Bit] = $false
                Write-TimelmAgentLog ('{0} up after {1} ms' -f $button.Name, $held)

                if (-not $longHandled[$button.Bit] -and $button.LongPress -gt 0 -and $button.ShortAction -ne 0) {
                    Invoke-TimelmAgentAction $button.ShortAction
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
