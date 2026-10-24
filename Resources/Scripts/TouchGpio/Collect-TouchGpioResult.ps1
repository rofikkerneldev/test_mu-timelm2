# SPDX-License-Identifier: BSD-2-Clause-Patent
# PC-side evidence collection for the one-boot GPIO touch trial. This script
# only reads the phone: it copies the boot log and the runtime log tree to
# the build PC, verifies every copy and writes a machine readable verdict.
param([Parameter(Mandatory=$true)][string]$Output, [switch]$TapSwipeObserved)
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {throw 'Run collection on the x64 PC, not the phone'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
. (Join-Path $PSScriptRoot 'Analyze-TouchGpioResult.ps1')
$expectedWindowsHash = 'fae47d78487e781aa06466775cb461adeb7ff7f887fe2c15295bb2eb4f4954e1'
# The trial launcher hash is a property of the staged bundle, not a constant.
# Read it from the bundle that was actually staged on the phone so a newer
# bundle is never mistaken for a restored Windows boot manager.
$expectedEspHash = $null
$copied = New-Object 'System.Collections.Generic.List[object]'
function Get-TouchGpioHash([string]$Path) {
    return (Get-SharedSha256 -LiteralPath $Path).Hash
}
function Copy-Verified([string]$Source, [string]$Destination) {
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Destination))
    [IO.File]::Copy($Source,$Destination,$true)
    $sourceHash = Get-TouchGpioHash $Source
    $copyHash = Get-TouchGpioHash $Destination
    if ($sourceHash -ne $copyHash) {throw "Copy verification failed: $Destination"}
    $copied.Add([ordered]@{source=$Source;copy=$Destination;bytes=(Get-Item -LiteralPath $Destination).Length;sha256=$copyHash})
}
function Copy-Tree([string]$Source, [string]$Destination) {
    if (!(Test-Path -LiteralPath $Source)) {return 0}
    $count = 0
    foreach ($file in [IO.Directory]::GetFiles($Source,'*',[IO.SearchOption]::AllDirectories)) {
        $relative = $file.Substring($Source.Length).TrimStart('\')
        Copy-Verified $file (Join-Path $Destination $relative)
        ++$count
    }
    return $count
}
$root = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $root) {
    if (!(Test-Path -LiteralPath $root -PathType Container)) {throw 'The output path is not a directory'}
} else {
    $null = [IO.Directory]::CreateDirectory($root)
}
if (Test-Path -LiteralPath (Join-Path $root 'result-status.json')) {throw 'Result collection already attempted in this directory'}
$disks = @(Get-Disk | Where-Object {$_.BusType -eq 'USB' -and $_.SerialNumber -and $_.SerialNumber.Trim() -eq '8509C01F'})
if ($disks.Count -ne 1 -or $disks[0].Size -ne 126374379520) {throw 'V60 USB disk mismatch'}
$disk = $disks[0]
$win = Get-Partition -DiskNumber $disk.Number -PartitionNumber 30
$esp = Get-Partition -DiskNumber $disk.Number -PartitionNumber 29
if ($win.Size -ne 63654666240 -or $esp.Size -ne 536870912 -or
    $esp.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') {throw 'V60 partition geometry mismatch'}
function Get-VolumeRoot($Partition) {
    $paths = @($Partition.AccessPaths | Where-Object {$_ -like '\\?\Volume*'})
    if ($paths.Count -ne 1) {throw 'Phone volume is not mounted'}
    return $paths[0]
}
$winRoot = Get-VolumeRoot $win
$espRoot = Get-VolumeRoot $esp
$bootFolder = Join-Path $root 'boot'
$runtimeFolder = Join-Path $root 'runtime'
$null = [IO.Directory]::CreateDirectory($bootFolder)
$null = [IO.Directory]::CreateDirectory($runtimeFolder)
$bootLog = Join-Path $espRoot 'timelm-touch-gpio.txt'
$bootLogPresent = Test-Path -LiteralPath $bootLog
if ($bootLogPresent) {Copy-Verified $bootLog (Join-Path $bootFolder 'timelm-touch-gpio.txt')}
$runtimeCopied = Copy-Tree (Join-Path $winRoot 'TimelmLogs\TouchGpioTrial') $runtimeFolder
$packageSource = Join-Path $winRoot 'TimelmTools\TouchGpioTrial\package.json'
if ((Test-Path -LiteralPath $packageSource) -and !(Test-Path -LiteralPath (Join-Path $runtimeFolder 'package.json'))) {
    Copy-Verified $packageSource (Join-Path $runtimeFolder 'package.json')
}
$launcherSource = Join-Path $winRoot 'TimelmTools\TouchGpioTrial\touch-gpio.json'
if (Test-Path -LiteralPath $launcherSource) {
    $launcherMeta = Get-Content -LiteralPath $launcherSource -Raw | ConvertFrom-Json
    if ($launcherMeta.sha256 -match '^[0-9a-fA-F]{64}$') { $expectedEspHash = $launcherMeta.sha256.ToLowerInvariant() }
}
$espState = foreach ($relative in @('EFI\Microsoft\Boot\bootmgfw.efi','EFI\Boot\bootaa64.efi',
    'EFI\Microsoft\Boot\bootmgfw.timelm-i2c-original.efi','EFI\Boot\bootaa64.timelm-i2c-original.efi')) {
    $path = Join-Path $espRoot $relative
    if (Test-Path -LiteralPath $path) {
        [ordered]@{path=$relative;bytes=(Get-Item -LiteralPath $path).Length;sha256=(Get-TouchGpioHash $path)}
    }
}
[ordered]@{phase='collected';utc=[DateTime]::UtcNow.ToString('o');serial='8509C01F';disk=$disk.Number;
    boot_log_present=$bootLogPresent;runtime_files=$runtimeCopied;copied=$copied.ToArray();esp=$espState;
    expected_trial_launcher_sha256=$expectedEspHash;expected_windows_boot_manager_sha256=$expectedWindowsHash} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'collection-status.json')
$restored = @($espState | Where-Object {$_.path -like '*.efi' -and $_.path -notlike '*-original.efi' -and $_.sha256 -eq $expectedWindowsHash}).Count
$stillTrial = if ($expectedEspHash) {@($espState | Where-Object {$_.path -like '*.efi' -and $_.path -notlike '*-original.efi' -and $_.sha256 -eq $expectedEspHash}).Count} else {0}
$verdict = Get-TouchGpioResult -Root $root -TapSwipeObserved:([bool]$TapSwipeObserved)
$verdict['esp_restored_to_windows'] = ($restored -eq 2)
$verdict['esp_still_trial'] = ($stillTrial -eq 2)
$verdict['collection'] = [ordered]@{boot_log_present=$bootLogPresent;runtime_files=$runtimeCopied;
    esp_restored_entries=$restored;esp_trial_entries=$stillTrial}
$verdict | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'result-status.json')
$lines = @('# GPIO touch trial result', '', ("verdict: " + $verdict['verdict']),
    ("tap and swipe: " + $verdict['tap_swipe']),
    ("ESP restored to the original Windows boot manager: " + $verdict['esp_restored_to_windows']), '')
foreach ($step in $verdict['steps'].Keys) {
    $entry = $verdict['steps'][$step]
    $lines += ("- {0}: {1} - {2}" -f $step,$entry['status'],$entry['detail'])
}
$lines | Set-Content -LiteralPath (Join-Path $root 'RESULT.md')
Write-Host ("Saved trial evidence to " + $root)
Write-Host ("verdict: " + $verdict['verdict'])
