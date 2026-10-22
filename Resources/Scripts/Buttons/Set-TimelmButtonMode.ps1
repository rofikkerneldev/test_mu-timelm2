<#
.SYNOPSIS
  Writes the button mapping into the driver of the phone.

.DESCRIPTION
  The mapping decides who reacts to a press of one of the three buttons.
  It can be changed while the phone is running, a new build of the driver
  is not needed.

      Agent  the agent answers the short presses with TAB, ENTER and the
             lock, the long presses with the context menu and the shutdown
             (the behaviour that was proven on the phone)
      Hid    the driver reports the button to Windows as a real HID key, so
             that the volume keys change the volume and the power key opens
             the power menu of Windows.  Only the long press is left to the
             agent.
      Both   both of them react, only useful to see the two paths at once

  The script has to run in the interactive session of the phone, as the
  agent does, because it writes the mapping that the agent reads.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Set-TimelmButtonMode.ps1 -Mode Hid

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Set-TimelmButtonMode.ps1 -Mode Agent
#>
[CmdletBinding()]
param(
    [ValidateSet('Agent', 'Hid', 'Both')]
    [string]$Mode = 'Hid',
    [int]$PowerLongPressMillis = 1500,
    [int]$VolumeDownLongPressMillis = 800
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1')

$names = @('Power', 'VolumeUp', 'VolumeDown')

function Get-TimelmActionName {
    param([int]$Action)
    switch ($Action) {
        1 { return 'TAB' }
        2 { return 'ENTER' }
        3 { return 'Shift+F10' }
        4 { return 'lock' }
        5 { return 'shutdown /s' }
        default { return 'none' }
    }
}

function Get-TimelmHidName {
    param([int]$Action)
    switch ($Action) {
        1 { return 'volume increment' }
        2 { return 'volume decrement' }
        3 { return 'system power down' }
        default { return 'none' }
    }
}

$handle = Open-TimelmButtons
try {
    $mapping = ConvertTo-TimelmButtonMapping `
        -Mode $Mode `
        -PowerLongPressMillis $PowerLongPressMillis `
        -VolumeDownLongPressMillis $VolumeDownLongPressMillis

    Set-TimelmButtonMapping -Handle $handle -Mapping $mapping

    $readBack = Get-TimelmButtonMapping -Handle $handle

    Write-Host ("mode : {0}" -f $Mode)
    Write-Host ("mapping version : {0}" -f $readBack.Version)

    for ($index = 0; $index -lt 3; $index++) {
        $source = $readBack.Source[$index]
        $action = $readBack.Action[$index]

        Write-Host ''
        Write-Host ("{0} (sid {1}, address 0x{2:X}, mask 0x{3:X}, polarity {4})" -f `
            $names[$index], $source.Sid, $source.Addr, $source.Mask, $source.Polarity)

        if ($action.HidEnabled -ne 0) {
            Write-Host ("   HID        : {0}" -f (Get-TimelmHidName ([int]$action.HidAction)))
        } else {
            Write-Host '   HID        : off'
        }

        Write-Host ("   agent short: {0}" -f (Get-TimelmActionName ([int]$action.AgentShortAction)))
        Write-Host ("   agent long : {0} (after {1} ms)" -f `
            (Get-TimelmActionName ([int]$action.AgentLongAction)), $action.LongPressMillis)
    }
}
finally {
    Close-TimelmButtons -Handle $handle
}
