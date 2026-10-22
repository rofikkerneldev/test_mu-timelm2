<#
.SYNOPSIS
  User mode agent for the LG V60 (timelm) hardware buttons.

.DESCRIPTION
  Reads the state of the four physical buttons from TimelmButtons.sys
  (\\.\TimelmButtons) and translates them into Windows input.

  What happens with a button is decided by the mapping of the driver, so
  the behaviour can be changed at run time without a new build:

      Volume Up            short press            -> TAB
      Volume Up            long press (1500 ms)   -> open the lock screen
      Volume Down          short press            -> ENTER
      Volume Down          long press (800 ms)    -> Shift+F10 (context menu)
      Power                short press            -> display off, press again
                                                    for display on
      Power                long press (1500 ms)   -> shutdown /s (clean shutdown)
      Assist               short press            -> the Windows key (the
                                                    start menu), or the
                                                    program of the target file
      Assist               long press (1500 ms)   -> Alt+F4, close the window
                                                    that has the focus

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

  A press is only answered when the button was quiet for the quiet time
  (500 ms by default).  The contact of the assist key of the phone can
  bounce, its pad has no pull up in the device tree of the gpio keys node,
  and a bouncing contact would otherwise open the start menu dozens of
  times.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File TimelmButtonAgent.ps1
#>
[CmdletBinding()]
param(
    [string]$LogPath = (Join-Path $env:ProgramData 'Timelm\button-agent.log'),
    [int]$WaitTimeoutMillis = 250,
    [int]$PowerLongPressMillis = 1500,
    [int]$VolumeUpLongPressMillis = 1500,
    [int]$VolumeDownLongPressMillis = 800,
    [int]$AssistLongPressMillis = 1500,
    [string]$AssistTargetPath = (Join-Path $env:ProgramData 'Timelm\assist-target.txt'),
    [string]$UnlockPassword = '',
    [int]$QuietMillis = 500,
    [int]$StuckMillis = 3000,
    [switch]$DisableLock,
    [switch]$DisableShutdown,
    [switch]$DryRun,
    [switch]$WakeInput,
    [int]$RunSeconds = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1')

if ($WakeInput) {
    <#
      The helper of the wake.  It runs in a short lived process, moves
      itself to the input desktop of the session and sends a harmless key,
      which wakes the lock screen.  The process ends right afterwards, so
      the agent itself stays on the desktop of the session.
    #>
    $errorCode = [TimelmButtonsNative]::WakeInputDesktop()
    $text = if ($errorCode -eq 0) { 'wake input desktop ok' } else { 'wake input desktop error {0}' -f $errorCode }
    try {
        $directory = Split-Path -Parent $LogPath
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $text) -Encoding UTF8
    } catch {
        # The log is not important for the result.
    }
    Write-Output $text
    exit $errorCode
}

$script:LogFile = $LogPath

# What the next short press of the power key does, 'Lock', 'Wake' or an
# empty string when the agent does not know it yet.
$script:TimelmPowerNext = ''

# True when the display of the phone is off.  The agent keeps the state,
# because Windows does not tell a program whether the display is on.
$script:TimelmDisplayOff = $false

#
# The password of the account of the phone.  The account of the phone has no
# password, the value of the registry is only used when it is there.
#
$script:TimelmUnlockPassword = $UnlockPassword
if (-not $script:TimelmUnlockPassword) {
    try {
        $value = Get-ItemPropertyValue `
            -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
            -Name 'DefaultPassword' `
            -ErrorAction Stop
        $script:TimelmUnlockPassword = [string]$value
    } catch {
        $script:TimelmUnlockPassword = ''
    }
}

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

function Get-TimelmLockState {
    <#
      The state of the lock of the session: 'Unlocked', 'Locked' or
      'Unknown'.  It is the answer of the name of the input desktop.
    #>
    $name = Get-TimelmInputDesktopName
    if (-not $name) { return 'Unknown' }
    if ($name -ieq 'Winlogon') { return 'Locked' }
    return 'Unlocked'
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

    if ($ok) {
        #
        # The switch to the secure desktop needs a moment, so the state is
        # read again.  It is only evidence for the log, the next press of
        # the power key wakes in any case.
        #
        Start-Sleep -Milliseconds 400
        Write-TimelmAgentLog ('after the lock the input desktop is {0}, the session is locked {1}' -f (Get-TimelmDesktopReport), (Get-TimelmLockState))
    }
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

    $report = Get-TimelmDesktopReport
    $state = Get-TimelmLockState
    $result = Invoke-TimelmWakeDisplay
    Write-TimelmAgentLog ('action wake (locked {0}, desktop {1}, previous state 0x{2:X}, nudge {3})' -f $state, $report, $result.PreviousState, $result.NudgeResult)

    #
    # The lock screen only wakes up for input that arrives at the secure
    # desktop, the helper sends it there.  The helper is harmless when the
    # session is not locked, the input desktop is then the desktop of the
    # session and the key is the shift key.
    #
    Invoke-TimelmWakeInputDesktop
}

function Invoke-TimelmWakeInputDesktop {
    <#
      Runs the helper of this script in a short lived process.  The helper
      moves itself to the input desktop of the session and sends a harmless
      key, which wakes the lock screen.
    #>
    $helper = $PSCommandPath
    if (-not $helper) {
        Write-TimelmAgentLog 'action wake input skipped (the path of the script is unknown)'
        return
    }

    try {
        $process = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
                          '-WakeInput', '-LogPath', $script:LogFile `
            -WindowStyle Hidden -Wait -PassThru
        Write-TimelmAgentLog ('action wake input helper exited with {0}' -f $process.ExitCode)
    } catch {
        Write-TimelmAgentLog ('action wake input helper failed: {0}' -f $_.Exception.Message)
    }
}

function Invoke-TimelmLockOrWake {
    <#
      Locks the workstation when it is unlocked and wakes the display when
      the session is locked.  That is the behaviour of the power key of a
      phone.

      The power key is a toggle, the press after a lock is a wake.  The name
      of the input desktop is only the evidence that the session is locked
      when the agent does not know it yet, because the name cannot always
      be read from a session that is locked.
    #>
    $name = Get-TimelmInputDesktopName
    $action = Resolve-TimelmPowerAction -DesktopName $name -Next $script:TimelmPowerNext
    Write-TimelmAgentLog ('the input desktop is {0}, the power key does {1}' -f (Get-TimelmDesktopReport), $action)

    if ($action -eq 'Lock') {
        Invoke-TimelmLock
        $script:TimelmPowerNext = 'Wake'
        return
    }

    Invoke-TimelmWake
    $script:TimelmPowerNext = 'Lock'
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

function Invoke-TimelmDisplayToggle {
    <#
      Turns the display of the phone off and on again, the same way as the
      power key of a phone.

      The session stays open, so the same key brings the user back to the
      desktop.  A lock without a way to open it again would be a trap, the
      phone has no working touch screen and no keyboard.

      The agent keeps the state of the display, because Windows does not
      tell a program whether the display is on.
    #>
    $turnOn = $script:TimelmDisplayOff

    if ($DryRun) {
        Write-TimelmAgentLog ('action display {0} (dry run)' -f $(if ($turnOn) { 'on' } else { 'off' }))
        return
    }

    [void][TimelmButtonsNative]::SetDisplayPower($turnOn)
    $script:TimelmDisplayOff = -not $turnOn

    Write-TimelmAgentLog ('action display {0}' -f $(if ($turnOn) { 'on' } else { 'off' }))
}

function Invoke-TimelmUnlock {
    <#
      Opens the lock screen of a locked session.

      The lock screen lives on the secure desktop of winlogon.exe, the
      agent cannot reach it with its own identity (the attempt 8 showed the
      error 5, the access was denied).  The helper of the native code works
      with the identity of winlogon.exe instead.

      The account of the phone has no password, so the sign in is done with
      the return key.
    #>
    if ($DryRun) {
        Write-TimelmAgentLog 'action unlock (dry run)'
        return
    }

    $state = Get-TimelmLockState
    if ($state -ne 'Locked') {
        Write-TimelmAgentLog ('action unlock skipped (the session is {0}), the display is woken instead' -f $state)
        Invoke-TimelmWake
        return
    }

    $code = [TimelmButtonsNative]::UnlockSecureDesktop($script:TimelmUnlockPassword)
    Write-TimelmAgentLog ('action unlock returned {0}' -f $code)
}

function Invoke-TimelmClose {
    <#
      Closes the window that has the focus, the same way as Alt+F4.

      The window of the agent and the console of the trial are never
      closed, the trial would end with them.
    #>
    if ($DryRun) {
        Write-TimelmAgentLog 'action close (dry run)'
        return
    }

    $code = [TimelmButtonsNative]::CloseForegroundWindow()
    Write-TimelmAgentLog ('action close (Alt+F4) returned {0}' -f $code)
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
    elseif ($Action -eq $script:TimelmAgentAction.DisplayToggle) {
        Invoke-TimelmDisplayToggle
    }
    elseif ($Action -eq $script:TimelmAgentAction.Unlock) {
        Invoke-TimelmUnlock
    }
    elseif ($Action -eq $script:TimelmAgentAction.Close) {
        Invoke-TimelmClose
    }
}

# Button bit -> index inside the driver state arrays (Power, VolumeUp, VolumeDown, Assist)
#
# The values are the fallback for a driver of the first version, which does
# not know the mapping.  As soon as the mapping of the driver is readable,
# it decides what the agent does.
$buttonTable = @(
    [pscustomobject]@{ Bit = 1; Name = 'Power'; Index = 0; LongPress = $PowerLongPressMillis; ShortAction = $script:TimelmAgentAction.DisplayToggle; LongAction = $script:TimelmAgentAction.Shutdown },
    [pscustomobject]@{ Bit = 2; Name = 'VolumeUp'; Index = 1; LongPress = $VolumeUpLongPressMillis; ShortAction = $script:TimelmAgentAction.Tab; LongAction = $script:TimelmAgentAction.Unlock },
    [pscustomobject]@{ Bit = 4; Name = 'VolumeDown'; Index = 2; LongPress = $VolumeDownLongPressMillis; ShortAction = $script:TimelmAgentAction.Enter; LongAction = $script:TimelmAgentAction.ShiftF10 },
    [pscustomobject]@{ Bit = 8; Name = 'Assist'; Index = 3; LongPress = $AssistLongPressMillis; ShortAction = $script:TimelmAgentAction.StartMenu; LongAction = $script:TimelmAgentAction.Close }
)

$handle = [IntPtr]::Zero
$mappingLoaded = $false

#
# The edges of the buttons, the helper keeps the state of every button and
# decides what has to be done with it.
#
$edges = New-TimelmButtonEdges -ButtonTable $buttonTable

#
# The console of the agent should not stand in front of the windows of the
# user, otherwise the key that closes a window would close the console.
# The display stays on while the agent runs, so that the state of the
# display is only changed by the power key of the phone.
#
try {
    [void][TimelmButtonsNative]::HideConsoleWindow()
    [void][TimelmButtonsNative]::SetKeepAwake($true)
} catch {
    Write-TimelmAgentLog ('the console could not be hidden: {0}' -f $_.Exception.Message)
}

try {
    $deadline = [DateTime]::UtcNow.AddSeconds($RunSeconds)
    $retry = 0

    while ($true) {
        #
        # The run time is checked first, so that the agent also ends when the
        # driver of the buttons never shows up.
        #
        if ($RunSeconds -gt 0 -and [DateTime]::UtcNow -ge $deadline) {
            Write-TimelmAgentLog 'run time reached, exiting'
            break
        }

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

            $decision = Get-TimelmButtonDecision `
                -Edges $edges `
                -Button $button `
                -Pressed $pressed `
                -Held $held `
                -QuietMillis $QuietMillis `
                -StuckMillis $StuckMillis

            if (-not $decision) { continue }

            switch ($decision.Kind) {
                'Ignored' {
                    Write-TimelmAgentLog ('{0} down ignored, {1}' -f $button.Name, $decision.Reason)
                }
                'Down' {
                    Write-TimelmAgentLog ('{0} down' -f $button.Name)
                }
                'Up' {
                    Write-TimelmAgentLog ('{0} up after {1} ms' -f $button.Name, $held)
                }
                'Short' {
                    Write-TimelmAgentLog ('{0} short press' -f $button.Name)
                    Invoke-TimelmAgentAction $decision.Action
                }
                'Long' {
                    Write-TimelmAgentLog ('{0} {1}' -f $button.Name, $decision.Reason)
                    Invoke-TimelmAgentAction $decision.Action
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
