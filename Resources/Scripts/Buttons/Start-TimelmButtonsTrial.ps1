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
#>
[CmdletBinding()]
param(
    [int]$Seconds = 120
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$trial = Join-Path $PSScriptRoot 'Run-TimelmButtonsTrial.ps1'
$package = Join-Path $PSScriptRoot 'Drivers\Buttons'

if (-not (Test-Path -LiteralPath $trial)) { throw 'The trial script is missing' }
if (-not (Test-Path -LiteralPath $package)) { throw 'The button driver package is missing' }

$arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Seconds {1} -PackagePath "{2}"' -f $trial, $Seconds, $package

Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Verb RunAs -ArgumentList $arguments
