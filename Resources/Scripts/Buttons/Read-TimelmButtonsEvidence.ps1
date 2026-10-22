<#
.SYNOPSIS
  Reads the evidence of a finished TimelmButtons trial.

.DESCRIPTION
  The trial writes the state of the buttons every 250 ms into
  button-state.jsonl and the actions of the agent into agent.log.  This
  script turns both files into a short report, so that the proof of a trial
  can be read without opening the raw files.

  The report tells three things:

    - the state of the HID face of the driver: was it ready, how many HID
      reports did it send
    - the presses of the buttons: short, long, how long they were held
    - the actions of the agent: which button did which action

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Read-TimelmButtonsEvidence.ps1 `
      -LogPath E:\TimelmLogs\TimelmButtonsTrial
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LogPath,
    [string]$Output
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LogPath -PathType Container)) {
    throw "The log folder does not exist: $LogPath"
}

$statePath = Join-Path $LogPath 'button-state.jsonl'
$agentPath = Join-Path $LogPath 'agent.log'
$modePath = Join-Path $LogPath 'button-mode.json'
$trialPath = Join-Path $LogPath 'trial.log'

$mode = $null
if (Test-Path -LiteralPath $modePath) {
    try { $mode = (Get-Content -LiteralPath $modePath -Raw | ConvertFrom-Json).mode } catch { $mode = $null }
}

#
# The state of an older trial has no HID fields, the reader has to work with
# both kinds of log.
#
function Get-Field($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

$states = @()
if (Test-Path -LiteralPath $statePath) {
    foreach ($line in Get-Content -LiteralPath $statePath) {
        if (-not $line.Trim()) { continue }
        try { $states += ($line | ConvertFrom-Json) } catch { }
    }
}

#
# The presses are the moments where the change counter moved.
#
$presses = @()
$previous = $null
foreach ($state in $states) {
    if ($null -ne $previous -and (Get-Field $state 'change_counter' 0) -gt (Get-Field $previous 'change_counter' 0)) {
        $buttons = @(Get-Field $state 'buttons' @())
        $held = @()
        foreach ($value in $buttons) {
            if ($value -ne 0) { $held += [int]$value }
        }
        $presses += [pscustomobject]@{
            utc = Get-Field $state 'utc'
            pressed = $held -join ','
            held_ms = (@(Get-Field $state 'held' @()) -join ',')
            press_count = Get-Field $state 'press_count'
            hid_ready = Get-Field $state 'hid_ready'
            hid_reports = Get-Field $state 'hid_reports'
        }
    }
    $previous = $state
}

$last = $states | Select-Object -Last 1
$hidReady = Get-Field $last 'hid_ready'
$hidReports = Get-Field $last 'hid_reports'

$agentActions = @()
if (Test-Path -LiteralPath $agentPath) {
    foreach ($line in Get-Content -LiteralPath $agentPath) {
        if ($line -match 'action\s+(?<action>\w+)\s+(?<button>\w+)') {
            $agentActions += [pscustomobject]@{ line = $line.Trim(); action = $Matches['action']; button = $Matches['button'] }
        }
    }
}

$trialLines = @()
if (Test-Path -LiteralPath $trialPath) {
    $trialLines = @(Get-Content -LiteralPath $trialPath)
}

$report = [ordered]@{
    log_path = $LogPath
    button_mode = $mode
    samples = $states.Count
    presses = $presses.Count
    hid_ready = $hidReady
    hid_reports = $hidReports
    press_details = $presses
    agent_actions = $agentActions
    trial_log = $trialLines
}

if ($Output) {
    $parent = Split-Path -Parent $Output
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Output -Encoding UTF8
}

Write-Output ("button mode    : {0}" -f $(if ($mode) { $mode } else { 'unknown' }))
Write-Output ("samples        : {0}" -f $states.Count)
Write-Output ("presses        : {0}" -f $presses.Count)
Write-Output ("hid ready      : {0}" -f $hidReady)
Write-Output ("hid reports    : {0}" -f $hidReports)
Write-Output ("agent actions  : {0}" -f $agentActions.Count)
Write-Output ''
foreach ($action in $agentActions) {
    Write-Output ("  agent : {0}" -f $action.line)
}
Write-Output ''
foreach ($press in $presses) {
    Write-Output ("  press : {0}  pressed={1}  held_ms={2}  hid_reports={3}" -f $press.utc, $press.pressed, $press.held_ms, $press.hid_reports)
}

if ($Output) {
    Write-Output ''
    Write-Output ("report written  : {0}" -f $Output)
}
