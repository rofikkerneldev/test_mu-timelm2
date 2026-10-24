# Read-only registry query in an expendable child process. No bus operations.
param([Parameter(Mandatory=$true)][string]$RegistryPath,
      [Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
if($RegistryPath -notlike 'HKLM:\*'){throw 'Expected an explicit HKLM registry path'}
$properties=Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction Stop
Write-TouchGpioJson $Output (ConvertTo-TouchGpioRegistryValues $properties)
