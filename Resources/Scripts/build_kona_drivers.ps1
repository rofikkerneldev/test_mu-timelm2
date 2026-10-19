param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination,
    [switch]$TimelmGpioFixes
)
$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path -LiteralPath $Source).Path
$null = New-Item -ItemType Directory -Force -Path $Destination
$Destination = (Resolve-Path -LiteralPath $Destination).Path
$expected = '3dcdec0bd59e3e77be92629b2ed9e095ae6e19e8'
$actual = (& git -C $Source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) { throw "Unexpected driver source: $actual" }
$patchMetadata = @()
if ($TimelmGpioFixes) {
    $overlay = Join-Path $PSScriptRoot '../DeviceOverlays/timelm/Drivers/KonaGPIO'
    $patch = (Resolve-Path -LiteralPath (Join-Path $overlay 'timelm-gpio.patch')).Path
    $helper = (Resolve-Path -LiteralPath (Join-Path $overlay 'PinConfig.h')).Path
    $targetHelper = Join-Path $Source 'src/GPIO/PinConfig.h'
    if ((Test-Path -LiteralPath $targetHelper) -and
        (Get-FileHash -LiteralPath $helper).Hash -ne (Get-FileHash -LiteralPath $targetHelper).Hash) {
        throw 'Existing PinConfig.h differs from the timelm helper'
    }
    & git -C $Source apply --check -- $patch 2>$null
    if ($LASTEXITCODE -eq 0) {
        & git -C $Source apply -- $patch
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply timelm GPIO patch' }
    } else {
        & git -C $Source apply --reverse --check -- $patch 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'GPIO source is neither clean nor already patched as expected' }
    }
    Copy-Item -LiteralPath $helper -Destination $targetHelper
    $patchMetadata = @($patch, $helper) | ForEach-Object {
        [ordered]@{name=[IO.Path]::GetFileName($_);sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
}
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\amd64\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild not found' }
$solutionDir = Join-Path $Source 'build\'
$metadata = [ordered]@{
    repository = 'https://github.com/WOA-Kona/Drivers'
    commit = $actual
    configuration = 'Debug'
    architecture = 'ARM64'
    target_os = 'Windows 11 ARM64; installed timelm OS is 26H2 build 26300.9457; hardware validation pending'
    kmdf = '1.33'
    components = @('GPIO','SPMI','PMIC')
    patches = $patchMetadata
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'source.json')
foreach ($component in $metadata.components) {
    $project = Join-Path $Source "src\$component\$component.vcxproj"
    $log = Join-Path $Destination "$component-build.log"
    & $msbuild $project /m /t:Rebuild /nologo /v:minimal /p:Configuration=Debug /p:Platform=ARM64 "/p:SolutionDir=$solutionDir" /p:KmdfLibraryVersion=1.33 /p:PreferredToolArchitecture=x64 "/flp:logfile=$log;verbosity=normal"
    if ($LASTEXITCODE -ne 0) { throw "$component build failed: $LASTEXITCODE" }
}
$output = Join-Path $Source 'build\ARM64\Debug\Output'
foreach ($component in $metadata.components) {
    $package = Join-Path $output $component
    if (-not (Test-Path -LiteralPath $package)) { throw "Missing package: $package" }
    Copy-Item -LiteralPath $package -Destination $Destination -Recurse
    $pdb = Join-Path $output "$component.pdb"
    if (Test-Path -LiteralPath $pdb) { Copy-Item -LiteralPath $pdb -Destination (Join-Path $Destination $component) }
}
$hashes = foreach ($file in Get-ChildItem -LiteralPath $Destination -Recurse -File) {
    if ($file.Extension -eq '.sys') {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $pe = [BitConverter]::ToInt32($bytes, 0x3c)
        if ([BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0xAA64) {
            throw "Not an ARM64 PE driver: $($file.Name)"
        }
    }
    [ordered]@{path=[IO.Path]::GetRelativePath($Destination,$file.FullName);sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();size=$file.Length}
}
$hashes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'sha256.json')
Write-Host 'All three ARM64 DEBUG packages built. Installation and hardware validation remain required.'
