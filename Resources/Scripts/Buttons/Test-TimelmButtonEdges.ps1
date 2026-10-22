<#
.SYNOPSIS
  Tests the edge logic of the button agent without the phone.

.DESCRIPTION
  The helper Get-TimelmButtonDecision in TimelmButtonsCommon.ps1 is pure,
  it only changes the table of the edges.  This script feeds it with the
  signals that the phone produces:

    * a clean press of every button,
    * a long press of the power key and of the volume down key,
    * the bouncing contact of the assist key, measured on the phone in the
      recovery (154 events in 43 s, a period of about 130 ms).

.EXAMPLE
  pwsh -NoProfile -File Test-TimelmButtonEdges.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1')

$script:Failures = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host ("ok   {0}" -f $Message)
    } else {
        Write-Host ("FAIL {0}" -f $Message)
        $script:Failures++
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -eq $Actual) {
        Write-Host ("ok   {0}" -f $Message)
    } else {
        Write-Host ("FAIL {0} (expected {1}, got {2})" -f $Message, $Expected, $Actual)
        $script:Failures++
    }
}

#
# The table of the buttons, the same as the one of the agent.
#
function Get-TestButtons {
    return @(
        [pscustomobject]@{ Bit = 1; Name = 'Power'; LongPress = 1500; ShortAction = 10; LongAction = 5 },
        [pscustomobject]@{ Bit = 2; Name = 'VolumeUp'; LongPress = 1500; ShortAction = 1; LongAction = 11 },
        [pscustomobject]@{ Bit = 4; Name = 'VolumeDown'; LongPress = 800; ShortAction = 2; LongAction = 3 },
        [pscustomobject]@{ Bit = 8; Name = 'Assist'; LongPress = 1500; ShortAction = 9; LongAction = 12 }
    )
}

#
# The table of the buttons of the attempt 8, the short press of the volume up
# key and of the assist key answered on the press itself and had no long
# press.
#
function Get-LegacyButtons {
    return @(
        [pscustomobject]@{ Bit = 1; Name = 'Power'; LongPress = 1500; ShortAction = 7; LongAction = 5 },
        [pscustomobject]@{ Bit = 2; Name = 'VolumeUp'; LongPress = 0; ShortAction = 1; LongAction = 0 },
        [pscustomobject]@{ Bit = 4; Name = 'VolumeDown'; LongPress = 800; ShortAction = 2; LongAction = 3 },
        [pscustomobject]@{ Bit = 8; Name = 'Assist'; LongPress = 0; ShortAction = 9; LongAction = 0 }
    )
}

#
# Feeds a signal into the helper and collects the answers.
#
function Invoke-Signal {
    param(
        $Edges,
        $Button,
        [bool[]]$Pressed,
        [int[]]$Held,
        [int]$StepMillis = 20,
        [int]$QuietMillis = 500,
        [int]$StuckMillis = 3000,
        [datetime]$Start = [datetime]'2026-01-01T00:00:00Z'
    )

    $answers = New-Object System.Collections.ArrayList
    $now = $Start

    for ($i = 0; $i -lt $Pressed.Count; $i++) {
        $now = $now.AddMilliseconds($StepMillis)
        $hold = 0
        if ($Held -and $i -lt $Held.Count) { $hold = $Held[$i] }
        $decision = Get-TimelmButtonDecision -Edges $Edges -Button $Button -Pressed $Pressed[$i] -Held $hold -QuietMillis $QuietMillis -StuckMillis $StuckMillis -Now $now
        if ($decision) { [void]$answers.Add($decision) }
    }

    return $answers
}

function Get-Actions {
    param($Answers)
    #
    # The comma keeps the array an array, Windows PowerShell 5.1 unrolls an
    # array of one element otherwise and the count of the result is lost.
    #
    return , @($Answers | Where-Object { $_.Kind -eq 'Short' -or $_.Kind -eq 'Long' })
}

Write-Host '--- a clean press of the volume up key answers with TAB ---'
$buttons = Get-TestButtons
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$answers = Invoke-Signal -Edges $edges -Button $buttons[1] -Pressed @($false, $true, $true, $false) -Held @(0, 0, 100, 100)
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'one action'
Assert-Equal 'Short' $actions[0].Kind 'the answer is a short press'
Assert-Equal 1 $actions[0].Action 'the action is TAB'

Write-Host '--- a clean press of the assist key answers with the start menu ---'
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$answers = Invoke-Signal -Edges $edges -Button $buttons[3] -Pressed @($false, $true, $true, $false) -Held @(0, 0, 120, 120)
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'one action'
Assert-Equal 'Short' $actions[0].Kind 'the answer is a short press'
Assert-Equal 9 $actions[0].Action 'the action is the start menu'

Write-Host '--- a long press of the volume down key answers with Shift+F10 ---'
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$pressed = @($false, $true, $true, $true, $true, $true, $false)
$held = @(0, 100, 400, 800, 900, 900, 900)
$answers = Invoke-Signal -Edges $edges -Button $buttons[2] -Pressed $pressed -Held $held
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'one action'
Assert-Equal 'Long' $actions[0].Kind 'the answer is a long press'
Assert-Equal 3 $actions[0].Action 'the action is Shift+F10'

Write-Host '--- a short press of the volume down key answers with ENTER ---'
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$answers = Invoke-Signal -Edges $edges -Button $buttons[2] -Pressed @($false, $true, $true, $false) -Held @(0, 100, 300, 300)
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'one action'
Assert-Equal 'Short' $actions[0].Kind 'the answer is a short press'
Assert-Equal 2 $actions[0].Action 'the action is ENTER'

Write-Host '--- a long press of the power key answers with the shutdown ---'
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$pressed = @($false, $true, $true, $true, $true, $true, $false)
$held = @(0, 200, 800, 1500, 1600, 1600, 1600)
$answers = Invoke-Signal -Edges $edges -Button $buttons[0] -Pressed $pressed -Held $held
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'one action'
Assert-Equal 'Long' $actions[0].Kind 'the answer is a long press'
Assert-Equal 5 $actions[0].Action 'the action is the shutdown'

Write-Host '--- the bouncing contact of the assist key answers once ---'
#
# The measured signal of the phone: the contact bounces with a period of
# about 130 ms, the phases are 120 ms pressed and 130 ms released.  The
# agent polls every 20 ms, the driver needs two equal samples.
#
$bouncePressed = New-Object System.Collections.ArrayList
$bounceHeld = New-Object System.Collections.ArrayList
for ($phase = 0; $phase -lt 140; $phase++) {
    $isPressed = ($phase % 2) -eq 0
    for ($i = 0; $i -lt 6; $i++) {
        [void]$bouncePressed.Add($isPressed)
        [void]$bounceHeld.Add(0)
    }
}

$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$answers = Invoke-Signal -Edges $edges -Button $buttons[3] -Pressed $bouncePressed.ToArray() -Held $bounceHeld.ToArray() -StepMillis 20
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'only one action for the whole bounce'
Assert-Equal 9 $actions[0].Action 'the action is the start menu'
Assert-True (@($answers | Where-Object { $_.Kind -eq 'Ignored' }).Count -gt 0) 'the other edges of the bounce are ignored'

Write-Host '--- a press after a quiet time is answered again ---'
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$afterQuiet = New-Object System.Collections.ArrayList
$afterHeld = New-Object System.Collections.ArrayList
foreach ($value in $bouncePressed) { [void]$afterQuiet.Add($value) }
foreach ($value in $bounceHeld) { [void]$afterHeld.Add($value) }
# 600 ms of quiet time, then a clean press
for ($i = 0; $i -lt 30; $i++) { [void]$afterQuiet.Add($false); [void]$afterHeld.Add(0) }
for ($i = 0; $i -lt 8; $i++) { [void]$afterQuiet.Add($true); [void]$afterHeld.Add(0) }
for ($i = 0; $i -lt 8; $i++) { [void]$afterQuiet.Add($false); [void]$afterHeld.Add(0) }
$answers = Invoke-Signal -Edges $edges -Button $buttons[3] -Pressed $afterQuiet.ToArray() -Held $afterHeld.ToArray() -StepMillis 20
$actions = Get-Actions $answers
Assert-Equal 2 $actions.Count 'the clean press after the quiet time is answered'

Write-Host '--- two quick presses are answered once ---'
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$pressed = @($false, $true, $true, $false, $true, $true, $false)
$held = @(0, 0, 100, 100, 0, 100, 100)
$answers = Invoke-Signal -Edges $edges -Button $buttons[1] -Pressed $pressed -Held $held -StepMillis 20
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'the second press is inside the quiet time'

Write-Host '--- the quiet time of a bouncing contact never ends ---'
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$answers = Invoke-Signal -Edges $edges -Button $buttons[3] -Pressed $bouncePressed.ToArray() -Held $bounceHeld.ToArray() -StepMillis 20
$edgesAfter = $edges[[int]$buttons[3].Bit]
Assert-True $edgesAfter.Locked 'the button is still locked after the bounce'

Write-Host '--- the power key is a toggle ---'
Assert-Equal 'Lock' (Resolve-TimelmPowerAction -DesktopName 'Default') 'the first press locks the screen'
Assert-Equal 'Wake' (Resolve-TimelmPowerAction -DesktopName 'Winlogon') 'a locked session is woken'
Assert-Equal 'Wake' (Resolve-TimelmPowerAction -DesktopName '') 'a name that cannot be read gives the wake'
Assert-Equal 'Wake' (Resolve-TimelmPowerAction -DesktopName 'Default' -Next 'Wake') 'the press after a lock wakes'
Assert-Equal 'Lock' (Resolve-TimelmPowerAction -DesktopName 'Default' -Next 'Lock') 'the press after a wake locks'
Assert-Equal 'Wake' (Resolve-TimelmPowerAction -DesktopName 'Winlogon' -Next 'Lock') 'the secure desktop wins over the toggle'

Write-Host '--- a contact that stays closed does not lock the button for ever ---'
#
# The contact of a button of the phone can stay closed.  The button was
# locked by the last action, the button must not stay locked for ever, and
# the button must not answer again while it is held down.
#
$legacy = Get-LegacyButtons
$edges = New-TimelmButtonEdges -ButtonTable $legacy -Now ([datetime]'2026-01-01T00:00:00Z')
$pressed = New-Object System.Collections.ArrayList
$held = New-Object System.Collections.ArrayList
[void]$pressed.Add($false)
[void]$held.Add(0)
for ($i = 0; $i -lt 20; $i++) { [void]$pressed.Add($true); [void]$held.Add(0) }   # a press that answers
for ($i = 0; $i -lt 300; $i++) { [void]$pressed.Add($true); [void]$held.Add(0) }  # the contact stays closed
$answers = Invoke-Signal -Edges $edges -Button $legacy[1] -Pressed $pressed.ToArray() -Held $held.ToArray() -StepMillis 20
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'the held button answers only once'
Assert-True (-not $edges[[int]$legacy[1].Bit].Locked) 'the lock of the button is given up'

Write-Host '--- a button that was held down answers again after a new press ---'
$edges = New-TimelmButtonEdges -ButtonTable $legacy -Now ([datetime]'2026-01-01T00:00:00Z')
$pressed = New-Object System.Collections.ArrayList
$held = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt 250; $i++) { [void]$pressed.Add($true); [void]$held.Add(0) }   # the contact stays closed
for ($i = 0; $i -lt 30; $i++) { [void]$pressed.Add($false); [void]$held.Add(0) }   # released
for ($i = 0; $i -lt 10; $i++) { [void]$pressed.Add($true); [void]$held.Add(0) }    # a new press
for ($i = 0; $i -lt 10; $i++) { [void]$pressed.Add($false); [void]$held.Add(0) }
$answers = Invoke-Signal -Edges $edges -Button $legacy[1] -Pressed $pressed.ToArray() -Held $held.ToArray() -StepMillis 20
$actions = Get-Actions $answers
Assert-Equal 2 $actions.Count 'the first press and the new press are answered'
Assert-Equal 1 $actions[1].Action 'the new press answers with the tab'

Write-Host '--- a second press of the power key answers again ---'
#
# The power key turns the display off and on again, both presses have to be
# answered.
#
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$pressed = New-Object System.Collections.ArrayList
$held = New-Object System.Collections.ArrayList
foreach ($value in @($false, $true, $true, $false)) { [void]$pressed.Add($value); [void]$held.Add(0) }
for ($i = 0; $i -lt 30; $i++) { [void]$pressed.Add($false); [void]$held.Add(0) }
foreach ($value in @($true, $true, $false)) { [void]$pressed.Add($value); [void]$held.Add(0) }
for ($i = 0; $i -lt 30; $i++) { [void]$pressed.Add($false); [void]$held.Add(0) }
$answers = Invoke-Signal -Edges $edges -Button $buttons[0] -Pressed $pressed.ToArray() -Held $held.ToArray() -StepMillis 20
$actions = Get-Actions $answers
Assert-Equal 2 $actions.Count 'both presses of the power key are answered'
Assert-Equal 10 $actions[0].Action 'the first press turns the display off'
Assert-Equal 10 $actions[1].Action 'the second press turns the display on again'
Assert-True (-not $edges[[int]$buttons[0].Bit].Locked) 'the lock of the power key is released by the quiet time'

Write-Host '--- a short press of the power key turns the display off and on ---'
#
# The power key of a phone turns the display off and on again.  The session
# stays open, a lock without a way to open it again would be a trap.
#
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$answers = Invoke-Signal -Edges $edges -Button $buttons[0] -Pressed @($false, $true, $true, $false) -Held @(0, 0, 120, 120)
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'one action'
Assert-Equal 'Short' $actions[0].Kind 'the answer is a short press'
Assert-Equal 10 $actions[0].Action 'the action is the display toggle'

Write-Host '--- a long press of the volume up key answers with the unlock ---'
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$pressed = @($false, $true, $true, $true, $true, $true, $false)
$held = @(0, 100, 700, 1500, 1600, 1600, 1600)
$answers = Invoke-Signal -Edges $edges -Button $buttons[1] -Pressed $pressed -Held $held
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'one action'
Assert-Equal 'Long' $actions[0].Kind 'the answer is a long press'
Assert-Equal 11 $actions[0].Action 'the action is the unlock'

Write-Host '--- a long press of the assist key answers with the close ---'
$edges = New-TimelmButtonEdges -ButtonTable $buttons -Now ([datetime]'2026-01-01T00:00:00Z')
$pressed = @($false, $true, $true, $true, $true, $true, $false)
$held = @(0, 100, 700, 1500, 1600, 1600, 1600)
$answers = Invoke-Signal -Edges $edges -Button $buttons[3] -Pressed $pressed -Held $held
$actions = Get-Actions $answers
Assert-Equal 1 $actions.Count 'one action'
Assert-Equal 'Long' $actions[0].Kind 'the answer is a long press'
Assert-Equal 12 $actions[0].Action 'the action is the close'

Write-Host '--- the mapping of the driver has the new actions ---'
$mapping = ConvertTo-TimelmButtonMapping -Mode Agent -Version 3
$decoded = ConvertFrom-TimelmButtonMapping $mapping
Assert-Equal 4 $decoded.Action.Count 'the mapping has four buttons'
Assert-Equal 1500 $decoded.Action[0].LongPressMillis 'the power key has a long press'
Assert-Equal 10 $decoded.Action[0].AgentShortAction 'the short press of the power key turns the display off and on'
Assert-Equal 5 $decoded.Action[0].AgentLongAction 'the long press of the power key shuts the phone down'
Assert-Equal 1500 $decoded.Action[1].LongPressMillis 'the volume up key has a long press'
Assert-Equal 1 $decoded.Action[1].AgentShortAction 'the short press of the volume up key answers with TAB'
Assert-Equal 11 $decoded.Action[1].AgentLongAction 'the long press of the volume up key opens the lock screen'
Assert-Equal 800 $decoded.Action[2].LongPressMillis 'the volume down key has a long press'
Assert-Equal 2 $decoded.Action[2].AgentShortAction 'the short press of the volume down key answers with ENTER'
Assert-Equal 3 $decoded.Action[2].AgentLongAction 'the long press of the volume down key answers with Shift+F10'
Assert-Equal 1500 $decoded.Action[3].LongPressMillis 'the assist key has a long press'
Assert-Equal 9 $decoded.Action[3].AgentShortAction 'the short press of the assist key opens the start menu'
Assert-Equal 12 $decoded.Action[3].AgentLongAction 'the long press of the assist key closes the window'

Write-Host '--- the names of the new actions are known ---'
Assert-Equal 'DisplayToggle' (Get-TimelmAgentActionName 10) 'the display toggle has a name'
Assert-Equal 'Unlock' (Get-TimelmAgentActionName 11) 'the unlock has a name'
Assert-Equal 'Close' (Get-TimelmAgentActionName 12) 'the close has a name'

if ($script:Failures -gt 0) {
    Write-Host ("{0} checks failed" -f $script:Failures)
    exit 1
}

Write-Host 'all checks passed'
