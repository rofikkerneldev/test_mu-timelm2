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
$output = Join-Path (Split-Path -Parent $project) "out/ARM64/$Configuration"
$package = Join-Path $output 'sw42902'
foreach ($name in @('vhidmini.sys','vhidmini.inf','sw42902.cat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $package $name))) { throw "Missing package file: $name" }
}
$bytes = [IO.File]::ReadAllBytes((Join-Path $package 'vhidmini.sys'))
$pe = [BitConverter]::ToInt32($bytes, 0x3c)
if ([BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0xAA64) {
    throw 'The touchscreen package is not ARM64'
}
$commit = (& git -C $repo rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to record source commit' }
[ordered]@{commit=$commit;configuration=$Configuration;architecture='ARM64';kmdf='1.33';hardware_validation='pending'} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'source.json')
& python (Join-Path $PSScriptRoot 'record_touch_source.py') --component touch --output (Join-Path $output 'source-inputs.json')
if($LASTEXITCODE -ne 0){throw 'Touch source provenance failed'}
$hashes = foreach ($file in Get-ChildItem -LiteralPath $output -File -Recurse) {
    if ($file.Name -eq 'sha256.json') { continue }
    [ordered]@{path=[IO.Path]::GetRelativePath($output,$file.FullName);sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();size=$file.Length}
}
$hashes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'sha256.json')
Write-Host 'Built an experimental peripheral driver. Working I2C SPB host, ACPI resources, signing and device validation are still required.'
