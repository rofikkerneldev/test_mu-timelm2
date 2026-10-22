<#
.SYNOPSIS
  Stages the TimelmButtons trial bundle on the LG V60 (timelm) phone.

.DESCRIPTION
  PC side staging only.  The script copies the button driver package and the
  trial scripts from a verified CI artifact onto the Windows partition of the
  identified phone and writes a receipt with the hashes of every staged file.

  The script never touches the ESP, the BCD or the boot order, the trial is a
  Windows side trial only.  The staged bundle is not armed automatically, the
  trial is started by the user on the phone.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Stage-TimelmButtonsTrial.ps1 `
      -Artifact C:\artifacts\timelm-native-buttons -Output C:\receipts\buttons

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Stage-TimelmButtonsTrial.ps1 `
      -Artifact C:\artifacts\timelm-native-buttons -Output C:\receipts\buttons `
      -ButtonMode Hid -Arm

.EXAMPLE
  # a second trial, the bundle and the receipts of the first one are
  # archived on the PC before they are removed from the phone
  powershell -ExecutionPolicy Bypass -File Stage-TimelmButtonsTrial.ps1 `
      -Artifact C:\artifacts\timelm-native-buttons -Output C:\receipts\buttons `
      -ButtonMode Agent -Replace
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Artifact,
    [Parameter(Mandatory = $true)][string]$Output,
    [ValidateSet('Agent', 'Hid', 'Both')]
    [string]$ButtonMode = 'Agent',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu')]
    [string]$AssistAction = 'StartMenu',
    [string]$AssistTarget = 'notepad.exe',
    [switch]$Arm,
    [switch]$Replace
)

$ErrorActionPreference = 'Stop'

if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw 'Run staging on the x64 PC, not on the phone' }

$modified = $false

function Write-Flushed([string]$Path, [byte[]]$Data) {
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $stream.Write($Data, 0, $Data.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Copy-Verified([string]$Source, [string]$Destination) {
    $bytes = [IO.File]::ReadAllBytes($Source)
    Write-Flushed $Destination $bytes
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $hash) {
        throw "Copy verification failed: $Destination"
    }
    return $hash
}

try {
    if (-not (Test-Path -LiteralPath $Output -PathType Container)) { throw 'Precreate the PC receipt directory' }
    $receiptRoot = (Get-Item -LiteralPath $Output).FullName
    $artifactRoot = (Get-Item -LiteralPath $Artifact).FullName

    $package = Join-Path $artifactRoot 'Buttons'
    if (-not (Test-Path -LiteralPath $package -PathType Container)) {
        throw 'The artifact does not contain the Buttons package'
    }

    $manifestPath = Join-Path $artifactRoot 'sha256.json'
    $sourcePath = Join-Path $artifactRoot 'source.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'The artifact has no sha256.json' }
    if (-not (Test-Path -LiteralPath $sourcePath)) { throw 'The artifact has no source.json' }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $provenance = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
    if ($provenance.architecture -ne 'ARM64') { throw 'The artifact is not an ARM64 build' }
    if ($provenance.commit -notmatch '^[0-9a-f]{40}$') { throw 'The artifact has no source revision' }

    foreach ($file in $manifest) {
        $path = Join-Path $artifactRoot $file.path
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing artifact file: $($file.path)" }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $file.sha256.ToLowerInvariant()) { throw "Artifact hash mismatch: $($file.path)" }
    }

    $sys = Join-Path $package 'TimelmButtons.sys'
    $inf = Join-Path $package 'TimelmButtons.inf'
    if (-not (Test-Path -LiteralPath $sys) -or -not (Test-Path -LiteralPath $inf)) {
        throw 'The Buttons package is incomplete'
    }
    $bytes = [IO.File]::ReadAllBytes($sys)
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0xaa64) {
        throw 'The button driver is not an ARM64 image'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $sys
    if (-not $signature.SignerCertificate) { throw 'The button driver is not signed' }

    $disks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.SerialNumber -and $_.SerialNumber.Trim() -eq '8509C01F' })
    if ($disks.Count -ne 1 -or $disks[0].Size -ne 126374379520 -or $disks[0].IsBoot -or $disks[0].IsSystem) {
        throw 'V60 USB disk mismatch'
    }
    $win = Get-Partition -DiskNumber $disks[0].Number -PartitionNumber 30
    if ($win.Offset -ne 62719688704 -or $win.Size -ne 63654666240 -or -not $win.DriveLetter) {
        throw 'V60 partition geometry mismatch'
    }
    $winRoot = [string]$win.DriveLetter + ':\'
    $volume = Get-Volume -DriveLetter $win.DriveLetter
    if ($volume.FileSystem -ne 'NTFS') { throw 'Wrong target filesystem' }

    foreach ($pcPath in @($receiptRoot, $artifactRoot)) {
        if ($pcPath -notmatch '^[A-Za-z]:\\') { throw 'Use an absolute PC drive-letter path for artifact and receipts' }
        $pcPartition = Get-Partition -DriveLetter $pcPath.Substring(0, 1)
        if ($pcPartition.DiskNumber -eq $disks[0].Number) { throw 'Artifact and receipt storage must not use any phone partition' }
    }

    $marker = Join-Path $winRoot 'TimelmTools\OobeHelper\timelm-device.marker'
    if (-not (Test-Path -LiteralPath $marker)) { throw 'Wrong installed Windows marker' }
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') { throw 'Wrong installed Windows marker' }

    $bundle = Join-Path $winRoot 'TimelmTools\TimelmButtonsTrial'
    $logDir = Join-Path $winRoot 'TimelmLogs\TimelmButtonsTrial'
    $startup = Join-Path $winRoot 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Timelm-buttons.cmd'

    #
    # A trial leaves its bundle, its receipts and possibly its startup entry
    # on the phone.  A second trial needs a clean phone, but the receipts of
    # the first one are evidence and are archived on the PC before they are
    # removed.
    #
    $archived = @()
    if ((Test-Path -LiteralPath $bundle) -or (Test-Path -LiteralPath $logDir)) {
        if (-not $Replace) {
            throw 'A previous button trial is still on the phone, use -Replace to archive it'
        }

        if (Test-Path -LiteralPath $logDir) {
            $archive = Join-Path $receiptRoot 'previous-trial-logs'
            if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Recurse -Force }
            Copy-Item -LiteralPath $logDir -Destination $archive -Recurse -Force
            $archived += 'TimelmLogs\TimelmButtonsTrial'
            Remove-Item -LiteralPath $logDir -Recurse -Force
        }
        if (Test-Path -LiteralPath $bundle) {
            Remove-Item -LiteralPath $bundle -Recurse -Force
            $archived += 'TimelmTools\TimelmButtonsTrial'
        }
        if (Test-Path -LiteralPath $startup) {
            Remove-Item -LiteralPath $startup -Force
            $archived += 'Startup\Timelm-buttons.cmd'
        }
        $modified = $true
    }

    $scripts = @(
        @{ source = (Join-Path $PSScriptRoot 'Run-TimelmButtonsTrial.ps1'); relative = 'Run-TimelmButtonsTrial.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'Start-TimelmButtonsTrial.ps1'); relative = 'Start-TimelmButtonsTrial.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'TimelmButtonAgent.ps1'); relative = 'TimelmButtonAgent.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1'); relative = 'TimelmButtonsCommon.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'Set-TimelmButtonMode.ps1'); relative = 'Set-TimelmButtonMode.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'Install-TimelmButtonAgent.ps1'); relative = 'Install-TimelmButtonAgent.ps1' },
        @{ source = $manifestPath; relative = 'sha256.json' },
        @{ source = $sourcePath; relative = 'source.json' }
    )
    foreach ($file in Get-ChildItem -LiteralPath $package -File) {
        $scripts += @{ source = $file.FullName; relative = ('Drivers/Buttons/' + $file.Name) }
    }

    $null = New-Item -ItemType Directory -Path $bundle
    $modified = $true

    #
    # The launcher of the trial carries the button mode, the mode of the
    # mapping is written by the trial before the agent starts.
    #
    $cmdSource = Join-Path $PSScriptRoot 'Timelm-buttons.cmd'
    $cmdText = [IO.File]::ReadAllText($cmdSource)
    if ($cmdText -notmatch '-ButtonMode\s+(Agent|Hid|Both)') { throw 'The trial launcher has no button mode' }
    $cmdText = $cmdText -replace '-ButtonMode\s+(Agent|Hid|Both)', ('-ButtonMode ' + $ButtonMode)
    if ($cmdText -notmatch '-AssistAction\s+\w+') { throw 'The trial launcher has no assist action' }
    $cmdText = $cmdText -replace '-AssistAction\s+\w+', ('-AssistAction ' + $AssistAction)
    $cmdPath = Join-Path $bundle 'Timelm-buttons.cmd'
    Write-Flushed $cmdPath ([Text.Encoding]::ASCII.GetBytes($cmdText))

    #
    # The target of the assist key is a text file, so the function of the
    # key can be changed without touching the agent.
    #
    $targetDir = Join-Path $winRoot 'ProgramData\Timelm'
    $null = New-Item -ItemType Directory -Force -Path $targetDir
    $targetFile = Join-Path $targetDir 'assist-target.txt'
    Write-Flushed $targetFile ([Text.Encoding]::ASCII.GetBytes($AssistTarget))

    # The reference time of the build PC.  The RTC of the phone runs hours
    # behind, the trial corrects the clock before it writes any receipt.
    $hostUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $bundle 'host-utc.txt'), $hostUtc)

    $hashes = foreach ($file in $scripts) {
        $destination = Join-Path $bundle ($file.relative -replace '/', '\')
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
        $hash = Copy-Verified $file.source $destination
        [ordered]@{ path = $file.relative; sha256 = $hash }
    }
    $hashes += [ordered]@{ path = 'host-utc.txt'; sha256 = (Get-FileHash -LiteralPath (Join-Path $bundle 'host-utc.txt') -Algorithm SHA256).Hash }
    $hashes += [ordered]@{ path = 'Timelm-buttons.cmd'; sha256 = (Get-FileHash -LiteralPath $cmdPath -Algorithm SHA256).Hash }
    $hashes += [ordered]@{ path = 'ProgramData/Timelm/assist-target.txt'; sha256 = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash }

    $staged = [ordered]@{
        phase = 'staged'
        utc = [DateTime]::UtcNow.ToString('o')
        serial = '8509C01F'
        disk = $disks[0].Number
        bundle = $bundle
        driver_commit = $provenance.commit
        driver_architecture = $provenance.architecture
        driver_configuration = $provenance.configuration
        driver_sha256 = (Get-FileHash -LiteralPath $sys -Algorithm SHA256).Hash
        inf_sha256 = (Get-FileHash -LiteralPath $inf -Algorithm SHA256).Hash
        button_mode = $ButtonMode
        assist_action = $AssistAction
        assist_target = $AssistTarget
        archived = $archived
        files = $hashes
        armed = $Arm.IsPresent
        esp_touched = $false
        bcd_changed = $false
        boot_order_changed = $false
    }
    $staged | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')

    if ($Arm) {
        $startup = Join-Path $winRoot 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Timelm-buttons.cmd'
        $bytes = [IO.File]::ReadAllBytes((Join-Path $bundle 'Timelm-buttons.cmd'))
        $stream = New-Object IO.FileStream($startup, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        if ((Get-FileHash -LiteralPath $startup -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $bundle 'Timelm-buttons.cmd') -Algorithm SHA256).Hash) {
            throw 'Startup readback failed'
        }
        $staged.armed = $true
        $staged.startup_sha256 = (Get-FileHash -LiteralPath $startup -Algorithm SHA256).Hash
        $staged | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')
    }

    Write-Host ("Button trial bundle staged on {0}" -f $bundle)
}
catch {
    $failure = $_.Exception.Message
    if ($modified -and (Test-Path -LiteralPath $bundle)) {
        Remove-Item -LiteralPath $bundle -Recurse -Force -ErrorAction SilentlyContinue
    }
    [ordered]@{ phase = 'failed'; error = $failure; utc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')
    throw
}
