# Refusal checks and validation of a real CI package. No phone/driver install.
param([string]$Artifact)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
if($Artifact){$null=Get-TouchGpioManifest $Artifact;'PASS: real package/INF/SYS/helper/provenance hashes';return}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('timelm-package-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
try {
    $existing=Join-Path $testRoot 'existing'
    $null=New-Item -ItemType Directory -Path $existing
    [IO.File]::WriteAllText((Join-Path $existing 'sentinel.txt'),'keep')
    $refused=$false
    try {& (Join-Path $PSScriptRoot 'Build-TouchGpioPackage.ps1') -GpioPackage $testRoot -HostPackage $testRoot -TouchPackage $testRoot -Trial $testRoot -Output $existing}
    catch {if($_.Exception.Message -ne 'Refusing to overwrite an existing bundle directory'){throw};$refused=$true}
    if(!$refused -or [IO.File]::ReadAllText((Join-Path $existing 'sentinel.txt')) -ne 'keep'){throw 'Existing output was modified'}
    $refused=$false
    try {& (Join-Path $PSScriptRoot 'Build-TouchGpioPackage.ps1') -GpioPackage $testRoot -HostPackage $testRoot -TouchPackage $testRoot -Trial $testRoot -Output (Join-Path $testRoot 'new')}
    catch {if($_.Exception.Message -notlike '*source-inputs.json*'){throw};$refused=$true}
    if(!$refused -or (Test-Path (Join-Path $testRoot 'new'))){throw 'A package without component provenance was created'}
    'PASS: no overwrite and no build without source provenance'
} finally {
    $absolute=[IO.Path]::GetFullPath($testRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$absolute.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or $absolute.Substring($parent.Length) -notmatch '^timelm-package-[a-f0-9]{32}$'){throw 'Unsafe package test cleanup'}
    if(Test-Path -LiteralPath $absolute){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
