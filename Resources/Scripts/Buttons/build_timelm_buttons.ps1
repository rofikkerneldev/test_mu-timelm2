<#
.SYNOPSIS
  Builds the TimelmButtons ARM64 driver from a pinned timelm_Drivers checkout.

.DESCRIPTION
  The button driver is developed in the timelm_Drivers repository
  (https://github.com/rofikkerneldev/timelm_Drivers).  This script verifies
  the pinned commit, builds src/Buttons/TimelmButtons.vcxproj for ARM64 and
  writes the package together with a source.json / sha256.json manifest so
  that the provenance of the artifact stays verifiable.

  Example:
    ./Resources/Scripts/Buttons/build_timelm_buttons.ps1 `
        -Source ./buttons-source -Destination ./buttons-packages
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$ExpectedCommit = '7b35cf5d1a6760e62ff5ad9600845dc110515b9f'
)

$ErrorActionPreference = 'Stop'

$Source = (Resolve-Path -LiteralPath $Source).Path
$null = New-Item -ItemType Directory -Force -Path $Destination
$Destination = (Resolve-Path -LiteralPath $Destination).Path

$actual = (& git -C $Source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the driver source revision' }

if ($ExpectedCommit -and $actual -notlike "$ExpectedCommit*") {
    throw "Unexpected driver source revision: $actual (expected $ExpectedCommit)"
}

& git -C $Source diff --quiet HEAD -- src/Buttons src/Include/TimelmButtons.h
if ($LASTEXITCODE -ne 0) { throw 'The button driver source contains uncommitted changes' }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\amd64\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild not found' }

$solutionDir = Join-Path $Source 'build\'
$project = Join-Path $Source 'src\Buttons\TimelmButtons.vcxproj'
$log = Join-Path $Destination 'Buttons-build.log'

& $msbuild $project /m /t:Rebuild /nologo /v:minimal /p:Configuration=Debug /p:Platform=ARM64 "/p:SolutionDir=$solutionDir" /p:KmdfLibraryVersion=1.33 /p:PreferredToolArchitecture=x64 "/flp:logfile=$log;verbosity=normal"
if ($LASTEXITCODE -ne 0) { throw "Buttons build failed: $LASTEXITCODE" }

$output = Join-Path $Source 'build\ARM64\Debug\Output\TimelmButtons'
if (-not (Test-Path -LiteralPath $output)) { throw "Missing build output: $output" }

$package = Join-Path $Destination 'Buttons'
Copy-Item -LiteralPath $output -Destination $package -Recurse -Force

$signed = Get-AuthenticodeSignature -LiteralPath (Join-Path $package 'TimelmButtons.sys')
if (!$signed.SignerCertificate) { throw 'Missing test signer certificate for TimelmButtons' }
[IO.File]::WriteAllBytes(
    (Join-Path $package 'TimelmButtons.cer'),
    $signed.SignerCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))

$metadata = [ordered]@{
    repository = 'https://github.com/rofikkerneldev/timelm_Drivers'
    commit = $actual
    configuration = 'Debug'
    architecture = 'ARM64'
    kmdf = '1.33'
    components = @('Buttons')
    description = 'TimelmButtons.sys, PMIC button sampler for the LG V60 power, volume and assist keys'
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'source.json')

$hashes = foreach ($file in Get-ChildItem -LiteralPath $Destination -Recurse -File) {
    if ($file.Extension -eq '.sys') {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $pe = [BitConverter]::ToInt32($bytes, 0x3c)
        if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0xAA64) {
            throw "Not an ARM64 PE driver: $($file.Name)"
        }
    }
    [ordered]@{ path = [IO.Path]::GetRelativePath($Destination, $file.FullName); sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); size = $file.Length }
}
$hashes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'sha256.json')

Write-Host 'TimelmButtons ARM64 Debug package built. Installation and hardware validation remain required.'
