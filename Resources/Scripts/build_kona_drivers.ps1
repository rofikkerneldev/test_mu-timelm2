param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination,
    [switch]$TimelmGpioFixes,
    [switch]$TimelmTouchFixes,
    [switch]$TimelmPowerFixes
)
$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path -LiteralPath $Source).Path
$null = New-Item -ItemType Directory -Force -Path $Destination
$Destination = (Resolve-Path -LiteralPath $Destination).Path
$expected = '3dcdec0bd59e3e77be92629b2ed9e095ae6e19e8'
$actual = (& git -C $Source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) { throw "Unexpected driver source: $actual" }
if (-not $TimelmPowerFixes) {
    & git -C $Source diff --quiet HEAD -- src/SPMI src/PMIC
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath (Join-Path $Source 'src/SPMI/Transaction.h'))) {
        throw 'SPMI/PMIC source contains prior changes; use a clean source for the touch-only build'
    }
}
$patchMetadata = @()
$metadataFiles = @()
if ($TimelmGpioFixes -or $TimelmTouchFixes) {
    $overlay = Join-Path $PSScriptRoot '../DeviceOverlays/timelm/Drivers/KonaGPIO'
    $patchName = if ($TimelmTouchFixes) { 'timelm-touch.patch' } else { 'timelm-gpio.patch' }
    $patch = (Resolve-Path -LiteralPath (Join-Path $overlay $patchName)).Path
    $helpers = @('PinConfig.h')
    if ($TimelmTouchFixes) { $helpers += 'TouchBus.h' }
    foreach ($name in $helpers) {
        $helper = (Resolve-Path -LiteralPath (Join-Path $overlay $name)).Path
        $targetHelper = Join-Path $Source ('src/GPIO/' + $name)
        if ((Test-Path -LiteralPath $targetHelper) -and
            (Get-FileHash -LiteralPath $helper).Hash -ne (Get-FileHash -LiteralPath $targetHelper).Hash) {
            throw "Existing $name differs from the timelm helper"
        }
    }
    & git -C $Source apply --check -- $patch 2>$null
    if ($LASTEXITCODE -eq 0) {
        & git -C $Source apply -- $patch
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply timelm GPIO patch' }
    } else {
        & git -C $Source apply --reverse --check -- $patch 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'GPIO source is neither clean nor already patched as expected' }
    }
    $metadataFiles = @($patch)
    foreach ($name in $helpers) {
        $helper = (Resolve-Path -LiteralPath (Join-Path $overlay $name)).Path
        Copy-Item -LiteralPath $helper -Destination (Join-Path $Source ('src/GPIO/' + $name))
        $metadataFiles += $helper
    }
}
# Touch pinmux does not require replacing the booting SPMI/PMIC drivers.
# The experimental power patch has a separate, explicit build option.
if ($TimelmPowerFixes) {
    $spmiOverlay = Join-Path $PSScriptRoot '../DeviceOverlays/timelm/Drivers/KonaSPMI'
    $powerPatch = (Resolve-Path -LiteralPath (Join-Path $spmiOverlay 'timelm-power.patch')).Path
    $transHelper = (Resolve-Path -LiteralPath (Join-Path $spmiOverlay 'Transaction.h')).Path
    $targetTrans = Join-Path $Source 'src/SPMI/Transaction.h'
    if ((Test-Path -LiteralPath $targetTrans) -and
        (Get-FileHash -LiteralPath $transHelper).Hash -ne (Get-FileHash -LiteralPath $targetTrans).Hash) {
        throw "Existing Transaction.h differs from the timelm helper"
    }
    & git -C $Source apply --check -- $powerPatch 2>$null
    if ($LASTEXITCODE -eq 0) {
        & git -C $Source apply -- $powerPatch
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply timelm power patch' }
    } else {
        & git -C $Source apply --reverse --check -- $powerPatch 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'SPMI/PMIC source is neither clean nor already patched as expected' }
    }
    Copy-Item -LiteralPath $transHelper -Destination $targetTrans
    $metadataFiles += @($powerPatch, $transHelper)
}
$patchMetadata = @($metadataFiles | ForEach-Object {
    [ordered]@{name=[IO.Path]::GetFileName($_);sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()}
})
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
    components = $(if($TimelmTouchFixes -and !$TimelmPowerFixes){@('GPIO')}else{@('GPIO','SPMI','PMIC')})
    patches = $patchMetadata
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'source.json')
& python (Join-Path $PSScriptRoot 'record_touch_source.py') --component gpio --output (Join-Path $Destination 'source-inputs.json') --upstream-root $Source
if($LASTEXITCODE -ne 0){throw 'GPIO source provenance failed'}
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
    $signed=Get-AuthenticodeSignature -LiteralPath (Join-Path $Destination "$component\$component.sys")
    if (!$signed.SignerCertificate) {throw "Missing test signer certificate for $component"}
    [IO.File]::WriteAllBytes((Join-Path $Destination "$component\$component.cer"),
        $signed.SignerCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
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
Write-Host 'Requested ARM64 DEBUG packages built. Installation and hardware validation remain required.'
