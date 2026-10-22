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
        [datetime]$Start = [datetime]'2026-01-01T00:00:00Z'
    )

    $answers = New-Object System.Collections.ArrayList
    $now = $Start

    for ($i = 0; $i -lt $Pressed.Count; $i++) {
        $now = $now.AddMilliseconds($StepMillis)
        $hold = 0
        if ($Held -and $i -lt $Held.Count) { $hold = $Held[$i] }
        $decision = Get-TimelmButtonDecision -Edges $Edges -Button $Button -Pressed $Pressed[$i] -Held $hold -QuietMillis $QuietMillis -Now $now
        if ($decision) { [void]$answers.Add($decision) }
    }

    return $answers
}

function Get-Actions {
    param($Answers)
    return @($Answers | Where-Object { $_.Kind -eq 'Short' -or $_.Kind -eq 'Long' })
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

if ($script:Failures -gt 0) {
    Write-Host ("{0} checks failed" -f $script:Failures)
    exit 1
}

Write-Host 'all checks passed'
