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

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-TimelmButtonAgent.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-TimelmButtonAgent.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:ProgramData 'Timelm'),
    [switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$startup = [Environment]::GetFolderPath('Startup')
$launcher = Join-Path $startup 'TimelmButtonAgent.cmd'
$agentSource = Join-Path $PSScriptRoot 'TimelmButtonAgent.ps1'
$commonSource = Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1'

Write-Host ("Startup folder : {0}" -f $startup)
Write-Host ("Install folder : {0}" -f $InstallDirectory)

if ($Uninstall) {
    if (Test-Path -LiteralPath $launcher) {
        Remove-Item -LiteralPath $launcher -Force
        Write-Host 'Startup entry removed'
    } else {
        Write-Host 'No startup entry found'
    }
    return
}

if (-not (Test-Path -LiteralPath $InstallDirectory)) {
    New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null
}

Copy-Item -LiteralPath $agentSource -Destination $InstallDirectory -Force
Copy-Item -LiteralPath $commonSource -Destination $InstallDirectory -Force

$agentPath = Join-Path $InstallDirectory 'TimelmButtonAgent.ps1'

$launcherContent = @(
    '@echo off',
    ('start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $agentPath)
) -join "`r`n"

[IO.File]::WriteAllText($launcher, $launcherContent + "`r`n", [Text.Encoding]::ASCII)
Write-Host ("Startup entry written : {0}" -f $launcher)
Write-Host ("Agent installed        : {0}" -f $agentPath)
Write-Host 'Sign out and back in (or restart) to start the agent.'
