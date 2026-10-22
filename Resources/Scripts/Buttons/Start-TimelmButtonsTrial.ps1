<#
.SYNOPSIS
  Starts the TimelmButtons trial in the interactive session of the phone.

.DESCRIPTION
  The trial needs an elevated process inside the session of the logged on
  user, because the agent sends input to that session and locks or shuts
  down the workstation from there.  This launcher is the piece that the
  Startup entry runs, it only re-launches the trial with the right
  privileges and does not change anything else.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Start-TimelmButtonsTrial.ps1 -Seconds 120

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Start-TimelmButtonsTrial.ps1 -Seconds 120 -ButtonMode Hid
#>
[CmdletBinding()]
param(
    [int]$Seconds = 120,
    [ValidateSet('Agent', 'Hid', 'Both')]
    [string]$ButtonMode = 'Agent',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left')]
    [string]$PowerAction = 'StartMenu',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left')]
    [string]$PowerLongAction = 'Shutdown',
    [int]$PowerLongPressMillis = 1500,
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left')]
    [string]$VolumeUpAction = 'Up',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left')]
    [string]$VolumeUpLongAction = 'Right',
    [int]$VolumeUpLongPressMillis = 800,
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left')]
    [string]$VolumeDownAction = 'Down',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left')]
    [string]$VolumeDownLongAction = 'Left',
    [int]$VolumeDownLongPressMillis = 800,
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left')]
    [string]$AssistAction = 'Enter',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left')]
    [string]$AssistLongAction = 'Tab',
    [int]$AssistLongPressMillis = 800,
    [string]$AssistTarget = 'notepad.exe'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$trial = Join-Path $PSScriptRoot 'Run-TimelmButtonsTrial.ps1'
$package = Join-Path $PSScriptRoot 'Drivers\Buttons'

if (-not (Test-Path -LiteralPath $trial)) { throw 'The trial script is missing' }
if (-not (Test-Path -LiteralPath $package)) { throw 'The button driver package is missing' }

$arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Seconds {1} -PackagePath "{2}" -ButtonMode {3} -PowerAction {4} -PowerLongAction {5} -PowerLongPressMillis {6} -VolumeUpAction {7} -VolumeUpLongAction {8} -VolumeUpLongPressMillis {9} -VolumeDownAction {10} -VolumeDownLongAction {11} -VolumeDownLongPressMillis {12} -AssistAction {13} -AssistLongAction {14} -AssistLongPressMillis {15} -AssistTarget "{16}"' -f `
    $trial, $Seconds, $package, $ButtonMode, $PowerAction, $PowerLongAction, $PowerLongPressMillis, `
    $VolumeUpAction, $VolumeUpLongAction, $VolumeUpLongPressMillis, $VolumeDownAction, $VolumeDownLongAction, `
    $VolumeDownLongPressMillis, $AssistAction, $AssistLongAction, $AssistLongPressMillis, $AssistTarget

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($elevated) {
    # The Startup entry of the phone already runs elevated, the child keeps
    # the privileges of this process.
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments
} else {
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList $arguments
}
