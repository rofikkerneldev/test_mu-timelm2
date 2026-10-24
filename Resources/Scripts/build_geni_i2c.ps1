param([ValidateSet('Debug','Release')][string]$Configuration = 'Debug')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Build Tools and ARM64 WDK are required' }
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\amd64\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild unavailable' }
$folder = Join-Path $repo 'GPLDrivers/Windows/KonaGeniI2c'
$output = Join-Path $folder "out/ARM64/$Configuration"
& $msbuild (Join-Path $folder 'kona_geni.vcxproj') /m /t:Rebuild /nologo /v:minimal "/p:Configuration=$Configuration" /p:Platform=ARM64
if ($LASTEXITCODE -ne 0) { throw "GENI I2C build failed: $LASTEXITCODE" }
$package = Join-Path $output 'kona_geni'
foreach ($name in @('kona_geni.sys','kona_geni.inf','kona_geni.cat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $package $name))) { throw "Missing package: $name" }
}
$bytes = [IO.File]::ReadAllBytes((Join-Path $package 'kona_geni.sys'))
$pe = [BitConverter]::ToInt32($bytes, 0x3c)
if ([BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0xAA64) {
    throw 'Not an ARM64 PE driver'
}
$commit = (& git -C $repo rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to record source revision' }
[ordered]@{commit=$commit;configuration=$Configuration;architecture='ARM64';kmdf='1.33';mode='bounded FIFO and GPI SPB bring-up';native_gpi='verified firmware BYPASS or experimental Windows IOMMU v2 translated domain; both disabled by default';native_board_init='optional Windows GCC/GPIO lifecycle; disabled by default';observed_recovery_transport='GPI DMA; real packet decoder validated in Recovery';firmware_handoff='shared SMMU handoff not validated; IORT candidate is not deployable';hardware_validation='Windows GPI not yet deployed'} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'source.json')
& python (Join-Path $PSScriptRoot 'record_touch_source.py') --component host --output (Join-Path $output 'source-inputs.json')
if($LASTEXITCODE -ne 0){throw 'Host source provenance failed'}
$hashes = foreach ($file in Get-ChildItem -LiteralPath $output -File -Recurse) {
    if ($file.Name -eq 'sha256.json') { continue }
    [ordered]@{path=[IO.Path]::GetRelativePath($output,$file.FullName);sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();size=$file.Length}
}
$hashes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'sha256.json')
Write-Host 'ARM64 FIFO/GPI SPB bring-up package built. Runtime/ACPI gates remain disabled; Windows hardware validation pending.'
