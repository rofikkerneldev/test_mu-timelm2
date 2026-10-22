<#
.SYNOPSIS
  Installs (or removes) the Timelm button agent for the interactive user.

.DESCRIPTION
  The agent has to run inside the interactive user session, therefore it is
  registered in the Startup folder of the user that runs this script.  Run it
  from the desktop of the phone, not from a service or from an elevated
  SYSTEM shell, otherwise the agent would run in the wrong session and
  SendInput would not reach the shell.

  The agent itself is copied to %ProgramData%\Timelm so that the Startup
  entry does not depend on the repository.

  With -StartNow the agent is started right away in the current session, so
  that the buttons work without a reboot.  The Startup entry stays, the
  agent runs again after the next sign in.

  With -Mode the mapping of the driver is written.  The mode decides who
  reacts to a short press:

      Agent  the agent answers with TAB, ENTER and the lock (the default)
      Hid    the driver reports the button as a native HID key, the agent
             only answers a long press
      Both   both of them react, only useful to see the two paths at once

  A driver of the first version does not know the mapping yet.  The script
  says so and keeps the behaviour of the driver, the agent falls back to
  the built in behaviour on its own.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-TimelmButtonAgent.ps1 -StartNow

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-TimelmButtonAgent.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:ProgramData 'Timelm'),
    [ValidateSet('Agent', 'Hid', 'Both')]
    [string]$Mode = 'Agent',
    [switch]$StartNow,
    [switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$startup = [Environment]::GetFolderPath('Startup')
$launcher = Join-Path $startup 'TimelmButtonAgent.cmd'
$agentSource = Join-Path $PSScriptRoot 'TimelmButtonAgent.ps1'
$commonSource = Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1'
$modeSource = Join-Path $PSScriptRoot 'Set-TimelmButtonMode.ps1'

Write-Host ("Startup folder : {0}" -f $startup)
Write-Host ("Install folder : {0}" -f $InstallDirectory)

if ($Uninstall) {
    if (Test-Path -LiteralPath $launcher) {
        Remove-Item -LiteralPath $launcher -Force
        Write-Host 'Startup entry removed'
    } else {
        Write-Host 'No startup entry found'
    }

    Write-Host 'A running agent is stopped when the phone is restarted.'
    return
}

if (-not (Test-Path -LiteralPath $InstallDirectory)) {
    New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null
}

Copy-Item -LiteralPath $agentSource -Destination $InstallDirectory -Force
Copy-Item -LiteralPath $commonSource -Destination $InstallDirectory -Force
if (Test-Path -LiteralPath $modeSource) {
    Copy-Item -LiteralPath $modeSource -Destination $InstallDirectory -Force
}

$agentPath = Join-Path $InstallDirectory 'TimelmButtonAgent.ps1'

$launcherContent = @(
    '@echo off',
    ('start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $agentPath)
) -join "`r`n"

[IO.File]::WriteAllText($launcher, $launcherContent + "`r`n", [Text.Encoding]::ASCII)
Write-Host ("Startup entry written : {0}" -f $launcher)
Write-Host ("Agent installed        : {0}" -f $agentPath)

#
# The mapping decides what the buttons do.  A driver of the first version
# does not know it, then the behaviour of the driver is kept and the agent
# uses its built in behaviour.
#
. (Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1')

$handle = [IntPtr]::Zero
try {
    $handle = Open-TimelmButtons

    $state = Get-TimelmButtonState -Handle $handle
    Write-Host ("Driver ready           : {0}" -f $state.Ready)
    Write-Host ("HID face available     : {0}" -f $state.HidReady)

    $mapping = ConvertTo-TimelmButtonMapping -Mode $Mode
    Set-TimelmButtonMapping -Handle $handle -Mapping $mapping

    $readBack = Get-TimelmButtonMapping -Handle $handle
    if ($readBack.Version -ge 2) {
        Write-Host ("Mapping written        : version {0}, mode {1}" -f $readBack.Version, $Mode)
    } else {
        Write-Host ("The driver still uses the mapping version {0}." -f $readBack.Version)
        Write-Host 'The behaviour of the driver is kept, the agent uses its built in behaviour.'
    }
} catch {
    Write-Host ("The driver is not reachable: {0}" -f $_.Exception.Message)
    Write-Host 'The agent is installed anyway, it waits for the driver.'
} finally {
    Close-TimelmButtons -Handle $handle
}

if ($StartNow) {
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $agentPath `
        -WindowStyle Hidden -PassThru
    Write-Host ("Agent started, pid {0}" -f $process.Id)
} else {
    Write-Host 'Sign out and back in (or restart) to start the agent.'
}
