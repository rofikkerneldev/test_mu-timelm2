param([ValidateSet('Debug','Release')][string]$Configuration = 'Debug')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Install Visual Studio Build Tools and the Windows 11 WDK with ARM64 support.' }
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\amd64\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild is unavailable. Install Visual Studio Build Tools and the Windows 11 WDK with ARM64 support.' }
$project = Join-Path $repo 'GPLDrivers/Windows/Sw42902Touch/driver/kmdf/sw42902.vcxproj'
& $msbuild $project /m /t:Rebuild /nologo /v:minimal "/p:Configuration=$Configuration" /p:Platform=ARM64
if ($LASTEXITCODE -ne 0) { throw "SW42902 build failed: $LASTEXITCODE" }
Write-Host 'Built an experimental peripheral driver. Working I2C SPB host, ACPI resources, signing and device validation are still required.'
