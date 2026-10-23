# PC-side staging only. Requires elevated access to the identified V60 USB disk.
param([Parameter(Mandatory=$true)][string]$Artifact,
      [Parameter(Mandatory=$true)][string]$Output,
      [switch]$ReArm)
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {throw 'Run staging on the x64 PC, not the phone'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
$modified = New-Object 'System.Collections.Generic.List[string]'
$original = $null; $startupCreated = $false; $verifiedDisk = $false; $receiptRoot = $null; $receiptWritable = $false
$archived = @()
$disarmedStartup = $false
$devMgrStartupCreated = $false
$devMgrDisarmed = $false
$buttonsStartupCreated = $false
$buttonsDisarmed = $false
$expectedWindowsHash = 'fae47d78487e781aa06466775cb461adeb7ff7f887fe2c15295bb2eb4f4954e1'
function Write-Flushed([string]$Path, [byte[]]$Data) {
    $f = [IO.FileStream]::new($Path,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
    try {$f.Write($Data,0,$Data.Length);$f.Flush($true)} finally {$f.Dispose()}
}
function Copy-Verified([string]$Source, [string]$Destination) {
    Write-Flushed $Destination ([IO.File]::ReadAllBytes($Source))
    $hash = (Get-FileHash -LiteralPath $Source).Hash
    if ((Get-FileHash -LiteralPath $Destination).Hash -ne $hash) {throw "Copy verification failed: $Destination"}
    return $hash
}
function Flush-Dismount {
    Write-VolumeCache -DriveLetter $win.DriveLetter
    $esp | Get-Volume | Write-VolumeCache
    & fsutil.exe volume dismount ($winRoot.TrimEnd('\')) *> (Join-Path $receiptRoot 'win-dismount.txt')
    if ($LASTEXITCODE -ne 0) {throw 'Windows dismount failed'}
    & fsutil.exe volume dismount ($espRoot.TrimEnd('\')) *> (Join-Path $receiptRoot 'esp-dismount.txt')
    if ($LASTEXITCODE -ne 0) {throw 'ESP dismount failed'}
}
try {
    if (!(Test-Path -LiteralPath $Output -PathType Container)) {throw 'Precreate the PC receipt directory'}
    $receiptRoot = (Get-Item -LiteralPath $Output).FullName
    if (Test-Path -LiteralPath (Join-Path $receiptRoot 'stage-status.json')) {throw 'Trial staging already attempted; inspect existing receipt'}
    $artifactRoot = (Get-Item -LiteralPath $Artifact).FullName
    $manifest = Get-TouchGpioManifest $artifactRoot
    $meta = Get-Content -LiteralPath (Join-Path $artifactRoot 'touch-gpio.json') -Raw | ConvertFrom-Json
    $launcher = Join-Path $artifactRoot 'TouchGpioOnce.efi'
    $aml = Join-Path $artifactRoot 'TouchGpio.aml'
    if ($meta.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        (Get-FileHash -LiteralPath $launcher).Hash -ne $meta.sha256 -or
        $meta.restores_windows_first -ne $true -or $meta.iort_installed -ne $false -or
        $meta.smmu_access -ne $false -or $meta.bbtrial -ne $true -or
        $meta.windows_reference.size -ne 3120648 -or $meta.windows_reference.sha256 -ne $expectedWindowsHash -or
        $meta.ssdt_sha256 -ne $manifest.ssdt_sha256 -or (Get-FileHash -LiteralPath $aml).Hash -ne $manifest.ssdt_sha256) {throw 'Wrong GPIO trial EFI/SSDT artifact'}
    $pe = [IO.File]::ReadAllBytes($launcher)
    if ($pe.Length -lt 256 -or $pe[0] -ne 0x4d -or $pe[1] -ne 0x5a) {throw 'Invalid launcher PE'}
    $peOffset = [BitConverter]::ToUInt32($pe,0x3c)
    if ($peOffset -gt $pe.Length-96 -or [BitConverter]::ToUInt32($pe,$peOffset) -ne 0x4550 -or
        [BitConverter]::ToUInt16($pe,$peOffset+4) -ne 0xaa64 -or [BitConverter]::ToUInt16($pe,$peOffset+92) -ne 10) {throw 'Launcher must be an ARM64 EFI application'}
    $disks = @(Get-Disk | Where-Object {$_.BusType -eq 'USB' -and $_.SerialNumber -and $_.SerialNumber.Trim() -eq '8509C01F'})
    if ($disks.Count -ne 1 -or $disks[0].Size -ne 126374379520 -or $disks[0].IsBoot -or $disks[0].IsSystem) {throw 'V60 USB disk mismatch'}
    $win = Get-Partition -DiskNumber $disks[0].Number -PartitionNumber 30
    $esp = Get-Partition -DiskNumber $disks[0].Number -PartitionNumber 29
    if ($win.Offset -ne 62719688704 -or $win.Size -ne 63654666240 -or !$win.DriveLetter -or
        $esp.Offset -ne 62182817792 -or $esp.Size -ne 536870912 -or
        $esp.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') {throw 'V60 partition geometry mismatch'}
    $winRoot = [string]$win.DriveLetter + ':\'
    $espPaths = @($esp.AccessPaths | Where-Object {$_ -like '\\?\Volume*'})
    if ($espPaths.Count -ne 1) {throw 'Unique ESP volume path unavailable'}
    $espRoot = $espPaths[0]
    if ($receiptRoot.StartsWith($winRoot,[StringComparison]::OrdinalIgnoreCase) -or
        $artifactRoot.StartsWith($winRoot,[StringComparison]::OrdinalIgnoreCase) -or
        $receiptRoot.StartsWith($espRoot,[StringComparison]::OrdinalIgnoreCase) -or
        $artifactRoot.StartsWith($espRoot,[StringComparison]::OrdinalIgnoreCase)) {throw 'Artifact and backups must be stored on the PC'}
    foreach ($pcPath in @($receiptRoot,$artifactRoot)) {
        if ($pcPath -notmatch '^[A-Za-z]:\\') {throw 'Use an absolute PC drive-letter path for artifact and receipts'}
        $pcPartition = Get-Partition -DriveLetter $pcPath.Substring(0,1)
        if ($pcPartition.DiskNumber -eq $disks[0].Number) {throw 'Artifact and receipt storage must not use any phone partition'}
    }
    $receiptWritable = $true
    $winVolume = Get-Volume -DriveLetter $win.DriveLetter
    $espVolume = $esp | Get-Volume
    if ($winVolume.FileSystem -ne 'NTFS' -or $espVolume.FileSystem -ne 'FAT32') {throw 'Wrong target filesystems'}
    if ((Get-Content -LiteralPath (Join-Path $winRoot 'TimelmTools\OobeHelper\timelm-device.marker') -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') {throw 'Wrong installed Windows marker'}
    $bundle = Join-Path $winRoot 'TimelmTools\TouchGpioTrial'
    $logs = Join-Path $winRoot 'TimelmLogs\TouchGpioTrial'
    $startup = Join-Path $winRoot 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Timelm-touch-gpio.cmd'
    if (Test-Path -LiteralPath $startup) {
        # A re-arm removes the Startup entry only when it is byte for byte the
        # entry this script staged. Any other entry is refused and never
        # disarmed, because it may belong to something else entirely.
        if (!$ReArm) {throw 'GPIO trial startup is still armed; refusing to rearm'}
        $stagedCmd = Join-Path $bundle 'Timelm-touch-gpio.cmd'
        if (!(Test-Path -LiteralPath $stagedCmd) -or
            (Get-FileHash -LiteralPath $startup).Hash -ne (Get-FileHash -LiteralPath $stagedCmd).Hash) {
            throw 'Startup entry is not this trial own; refusing to disarm it'
        }
        Remove-Item -LiteralPath $startup -Force
        $disarmedStartup = $true
    }
    # The Device Manager helper is a second Startup entry. It only displays the
    # console, and it is disarmed by the same rule as the trial entry: only an
    # entry that this script staged byte for byte may be removed.
    $devMgrStartup = Join-Path $winRoot 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Timelm-device-manager.cmd'
    if (Test-Path -LiteralPath $devMgrStartup) {
        if (!$ReArm) {throw 'GPIO trial device manager startup is still armed; refusing to rearm'}
        $stagedDevMgrCmd = Join-Path $bundle 'Timelm-device-manager.cmd'
        if (!(Test-Path -LiteralPath $stagedDevMgrCmd) -or
            (Get-FileHash -LiteralPath $devMgrStartup).Hash -ne (Get-FileHash -LiteralPath $stagedDevMgrCmd).Hash) {
            throw 'Device manager startup entry is not this trial own; refusing to disarm it'
        }
        Remove-Item -LiteralPath $devMgrStartup -Force
        $devMgrDisarmed = $true
    }
    # The button trial is a third Startup entry. It keeps the Volume, Power and
    # Assist keys usable while the touch trial is on the screen. It is
    # disarmed by the same rule as the other entries: only an entry that this
    # script staged byte for byte may be removed.
    $buttonsStartup = Join-Path $winRoot 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Timelm-buttons.cmd'
    if (Test-Path -LiteralPath $buttonsStartup) {
        if (!$ReArm) {throw 'GPIO trial button startup is still armed; refusing to rearm'}
        $stagedButtonsCmd = Join-Path $bundle 'Timelm-buttons.cmd'
        if (!(Test-Path -LiteralPath $stagedButtonsCmd) -or
            (Get-FileHash -LiteralPath $buttonsStartup).Hash -ne (Get-FileHash -LiteralPath $stagedButtonsCmd).Hash) {
            throw 'Button startup entry is not this trial own; refusing to disarm it'
        }
        Remove-Item -LiteralPath $buttonsStartup -Force
        $buttonsDisarmed = $true
    }
    if ((Test-Path -LiteralPath $bundle) -or (Test-Path -LiteralPath $logs)) {
        # A re-arm is only allowed for this bundle's own leftovers. The staged
        # manifest must match the artifact and the runtime log must carry this
        # trial's receipts; a phone in any other state is refused instead.
        if (!$ReArm) {throw 'GPIO trial already exists; refusing to rearm'}
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        if (Test-Path -LiteralPath $bundle) {
            $null = Get-TouchGpioManifest $bundle
            if ((Get-FileHash -LiteralPath (Join-Path $bundle 'package.json')).Hash -ne
                (Get-FileHash -LiteralPath (Join-Path $artifactRoot 'package.json')).Hash) {throw 'Staged bundle is not this artifact'}
            $staleBundle = Join-Path $winRoot ('TimelmTools\TouchGpioTrial-stale-' + $stamp)
            Move-Item -LiteralPath $bundle -Destination $staleBundle
            $archived += $staleBundle
        }
        if (Test-Path -LiteralPath $logs) {
            $staleLogs = Join-Path $winRoot ('TimelmLogs\TouchGpioTrial-stale-' + $stamp)
            Move-Item -LiteralPath $logs -Destination $staleLogs
            $archived += $staleLogs
        }
    }
    $installed = @(Get-ChildItem -LiteralPath (Join-Path $winRoot 'Windows\INF') -Filter '*.inf' -File)
    if ($installed.Count -lt 100) {throw 'Incomplete installed INF enumeration'}
    foreach ($p in $manifest.packages) {
        $pattern = switch ($p.name) {GPIO {'ACPI\\KONA1001'} Host {'ACPI\\TIML0001'} Touch {'ACPI\\LGSW4290'}}
        $newHash = @($manifest.files | Where-Object {$_.path -ceq ('Drivers/'+$p.name+'/'+$p.inf)})[0].sha256
        $allowed = @($p.replaces_inf_sha256) + @($newHash)
        foreach ($match in @($installed | Select-String -Pattern $pattern -List)) {
            if ((Get-FileHash -LiteralPath $match.Path).Hash -notin $allowed) {throw "Unreviewed installed $($p.name) INF"}
        }
    }
    $targets = @('EFI\Microsoft\Boot\bootmgfw.efi','EFI\Boot\bootaa64.efi')
    $backups = @('EFI\Microsoft\Boot\bootmgfw.timelm-i2c-original.efi','EFI\Boot\bootaa64.timelm-i2c-original.efi')
    foreach ($rel in $targets) {
        $src = $espRoot + $rel
        if ((Get-Item -LiteralPath $src).Length -ne 3120648 -or (Get-FileHash -LiteralPath $src).Hash -ne $expectedWindowsHash) {throw 'Active Windows boot manager reference mismatch'}
        $dest = Join-Path $receiptRoot ('before\'+$rel)
        $null = New-Item -ItemType Directory -Path (Split-Path $dest) -Force
        $null = Copy-Verified $src $dest
    }
    foreach ($rel in $backups) {
        if ((Test-Path -LiteralPath ($espRoot+$rel)) -and
            (Get-FileHash -LiteralPath ($espRoot+$rel)).Hash -ne $expectedWindowsHash) {throw 'Stale restore-first EFI backup'}
    }
    $bcd = $espRoot + 'EFI\Microsoft\Boot\BCD'
    $bcdHash = Copy-Verified $bcd (Join-Path $receiptRoot 'BCD-before-touch-gpio')
    $original = [IO.File]::ReadAllBytes((Join-Path $receiptRoot ('before\'+$targets[0])))
    $verifiedDisk = $true
    [ordered]@{phase='preflight-verified';utc=[DateTime]::UtcNow.ToString('o');serial='8509C01F';disk=$disks[0].Number;
        startup_before='absent';manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $artifactRoot 'package.json')).Hash} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')
    foreach ($rel in $backups) {
        if (!(Test-Path -LiteralPath ($espRoot+$rel))) {Write-Flushed ($espRoot+$rel) $original}
        if ((Get-FileHash -LiteralPath ($espRoot+$rel)).Hash -ne $expectedWindowsHash) {throw 'Restoration backup readback failed'}
    }
    # The host gate is written in the phone hive before the trial boot. The
    # host driver reads NativeGpioI2cEnabled when the device starts, and that
    # start happens in the very boot that carries the trial SSDT. A device
    # that failed to start keeps the PnP lock of its parameters key, so the
    # value can not be written while the phone runs: the hive is edited here
    # instead, with the phone off. Every other gate stays zero, the bitbang
    # path refuses to run when one of them is set.
    # Arm one is reserved for a resumed attempt: when this exact bundle's own
    # host INF is already installed, the resumed boot's first start is the one
    # that must reach the bitbang prepare path. A clean bundle stages the gate
    # at zero: the runner verifies the zero state, upgrades the driver bundle
    # and arms the gate by itself before restarting the device. Pre-arming a
    # clean bundle would only trip the runner's pre-existing-gate guard
    # (trial 9: the guard threw at 05:13:50Z before any baseline was written).
    $hostPkg = @($manifest.packages | Where-Object {$_.name -ceq 'Host'})[0]
    $hostInfRel = 'Drivers/' + $hostPkg.name + '/' + $hostPkg.inf
    $hostInfHash = @($manifest.files | Where-Object {$_.path -ceq $hostInfRel})[0].sha256
    $resumeFromInstalledInf = $false
    foreach ($match in @($installed | Select-String -Pattern 'ACPI\\TIML0001' -List)) {
        if ((Get-FileHash -LiteralPath $match.Path).Hash -eq $hostInfHash) {$resumeFromInstalledInf = $true}
    }
    $gateTarget = if ($resumeFromInstalledInf) {1} else {0}
    $gateReceipt = Join-Path $receiptRoot 'host-gate.json'
    $gateOutput = & (Join-Path $PSScriptRoot 'Arm-TouchGpioHostGate.ps1') -WindowsRoot $winRoot -Receipt $gateReceipt -GateValue $gateTarget 2>&1
    $gateArmed = Test-Path -LiteralPath $gateReceipt
    if (!$gateArmed) {throw "Host gate staging failed: $gateOutput"}
    $null = New-Item -ItemType Directory -Path $bundle
    $sources = @(
        @{source=(Join-Path $PSScriptRoot 'Launch-TouchGpioTrial.ps1');relative='Launch-TouchGpioTrial.ps1'},
        @{source=(Join-Path $PSScriptRoot 'Run-TouchGpioTrial.ps1');relative='Run-TouchGpioTrial.ps1'},
        @{source=(Join-Path $PSScriptRoot 'TouchGpioCommon.ps1');relative='TouchGpioCommon.ps1'},
        @{source=(Join-Path $PSScriptRoot 'Timelm-touch-gpio.cmd');relative='Timelm-touch-gpio.cmd'},
        @{source=(Join-Path $PSScriptRoot 'TouchGpioDeviceManager.ps1');relative='TouchGpioDeviceManager.ps1'},
        @{source=(Join-Path $PSScriptRoot 'Timelm-device-manager.cmd');relative='Timelm-device-manager.cmd'},
        @{source=(Join-Path $PSScriptRoot 'Timelm-buttons.cmd');relative='Timelm-buttons.cmd'},
        @{source=(Join-Path $PSScriptRoot 'Watch-DeviceNodes.ps1');relative='Watch-DeviceNodes.ps1'},
        @{source=(Join-Path (Split-Path $PSScriptRoot) 'TouchEnumeration\Invoke-ProbeProcess.ps1');relative='Invoke-ProbeProcess.ps1'},
        @{source=(Join-Path (Split-Path $PSScriptRoot) 'Collect-TimelmDiagnostics.ps1');relative='Collect-TimelmDiagnostics.ps1'},
        @{source=(Join-Path $artifactRoot 'package.json');relative='package.json'},
        @{source=(Join-Path $artifactRoot 'touch-gpio.json');relative='touch-gpio.json'},
        @{source=$aml;relative='TouchGpio.aml'})
    foreach ($file in $manifest.files) {$sources += @{source=(Join-Path $artifactRoot $file.path);relative=$file.path}}
    $hashes = foreach ($source in $sources) {
        $dest = Join-Path $bundle $source.relative
        $null = New-Item -ItemType Directory -Path (Split-Path $dest) -Force
        $hash = Copy-Verified $source.source $dest
        [ordered]@{path=$source.relative;sha256=$hash}
    }
    [DateTime]::UtcNow.ToString('o') | Set-Content -LiteralPath (Join-Path $bundle 'host-utc.txt')
    $hashes += [ordered]@{path='host-utc.txt';sha256=(Get-FileHash -LiteralPath (Join-Path $bundle 'host-utc.txt')).Hash}
    $null = Get-TouchGpioManifest $bundle
    # Preserve the exact staged startup/helper on the PC before arming it.
    $null = Copy-Verified (Join-Path $bundle 'Timelm-touch-gpio.cmd') (Join-Path $receiptRoot 'startup-staged.cmd')
    $null = Copy-Verified (Join-Path $bundle 'Timelm-device-manager.cmd') (Join-Path $receiptRoot 'device-manager-startup-staged.cmd')
    $startupBytes = [IO.File]::ReadAllBytes((Join-Path $bundle 'Timelm-touch-gpio.cmd'))
    $startupStream = [IO.FileStream]::new($startup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
    $startupCreated = $true
    try {$startupStream.Write($startupBytes,0,$startupBytes.Length);$startupStream.Flush($true)} finally {$startupStream.Dispose()}
    if ((Get-FileHash -LiteralPath $startup).Hash -ne (Get-FileHash -LiteralPath (Join-Path $bundle 'Timelm-touch-gpio.cmd')).Hash) {throw 'Startup readback failed'}
    # The Device Manager helper runs in the same desktop session as the trial
    # bootstrap, so the console opens on the visible screen. It is written with
    # CreateNew as well: an entry that already exists is never overwritten.
    $devMgrBytes = [IO.File]::ReadAllBytes((Join-Path $bundle 'Timelm-device-manager.cmd'))
    $devMgrStream = [IO.FileStream]::new($devMgrStartup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
    $devMgrStartupCreated = $true
    try {$devMgrStream.Write($devMgrBytes,0,$devMgrBytes.Length);$devMgrStream.Flush($true)} finally {$devMgrStream.Dispose()}
    if ((Get-FileHash -LiteralPath $devMgrStartup).Hash -ne (Get-FileHash -LiteralPath (Join-Path $bundle 'Timelm-device-manager.cmd')).Hash) {throw 'Device manager startup readback failed'}
    # The phone volume is dismounted before the receipt is written, so the
    # hash of the armed entry is captured here and not read again later.
    $devMgrStartupHash = (Get-FileHash -LiteralPath $devMgrStartup).Hash
    # The button trial entry is only armed when the button trial bundle of
    # this phone is still on the volume. It starts the button trial in the
    # interactive session, so the Volume, Power and Assist keys stay usable
    # while the touch trial is on the screen.
    $buttonsStartupHash = $null
    $buttonsArmed = $false
    $buttonsBundle = Join-Path $winRoot 'TimelmTools\TimelmButtonsTrial\Start-TimelmButtonsTrial.ps1'
    if (Test-Path -LiteralPath $buttonsBundle) {
        $null = Copy-Verified (Join-Path $bundle 'Timelm-buttons.cmd') (Join-Path $receiptRoot 'buttons-startup-staged.cmd')
        $buttonsBytes = [IO.File]::ReadAllBytes((Join-Path $bundle 'Timelm-buttons.cmd'))
        $buttonsStream = [IO.FileStream]::new($buttonsStartup,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        $buttonsStartupCreated = $true
        try {$buttonsStream.Write($buttonsBytes,0,$buttonsBytes.Length);$buttonsStream.Flush($true)} finally {$buttonsStream.Dispose()}
        if ((Get-FileHash -LiteralPath $buttonsStartup).Hash -ne (Get-FileHash -LiteralPath (Join-Path $bundle 'Timelm-buttons.cmd')).Hash) {throw 'Button startup readback failed'}
        $buttonsStartupHash = (Get-FileHash -LiteralPath $buttonsStartup).Hash
        $buttonsArmed = $true
    }
    foreach ($rel in $targets) {
        $dest = $espRoot + $rel
        $modified.Add($dest)
        Write-Flushed $dest $pe
        if ((Get-FileHash -LiteralPath $dest).Hash -ne $meta.sha256) {throw 'Trial EFI readback failed'}
    }
    if ((Get-FileHash -LiteralPath $bcd).Hash -ne $bcdHash) {throw 'BCD changed during trial staging'}
    Flush-Dismount
    [ordered]@{phase='ready-for-one-boot-touch-gpio';utc=[DateTime]::UtcNow.ToString('o');launcher=$meta;helper_files=$hashes;
        serial='8509C01F';disk=$disks[0].Number;checked_installed_infs=$installed.Count;package=$manifest;
        bcd_before_after=$bcdHash;iort_installed=$false;boot_partition_flashed=$false;runtime_install_order=@('GPIO','Host','Touch');
        test_seconds=120;automatic_reboot=$false;normal_shutdown=$true;flushed_and_dismounted=$true;
        rearm=$ReArm.IsPresent;disarmed_startup=$disarmedStartup;archived_leftovers=$archived;
        device_manager_startup='Timelm-device-manager.cmd';device_manager_startup_sha256=$devMgrStartupHash;
        disarmed_device_manager_startup=$devMgrDisarmed;host_gate=$gateTarget;host_gate_resume=$resumeFromInstalledInf;host_gate_receipt='host-gate.json';
        buttons_startup='Timelm-buttons.cmd';buttons_startup_sha256=$buttonsStartupHash;buttons_armed=$buttonsArmed;
        disarmed_buttons_startup=$buttonsDisarmed} |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')
} catch {
    $failure = $_.Exception.Message; $rollback = @()
    foreach ($dest in $modified) {
        try {
            Write-Flushed $dest $original
            if ((Get-FileHash -LiteralPath $dest).Hash -ne $expectedWindowsHash) {throw 'EFI rollback hash mismatch'}
        } catch {$rollback += $_.Exception.Message}
    }
    if ($startupCreated -and (Test-Path -LiteralPath $startup)) {
        try {
            # This path was opened with CreateNew by this attempt, so even a
            # partial write belongs to us and must be disarmed on rollback.
            Remove-Item -LiteralPath $startup
        } catch {$rollback += $_.Exception.Message}
    }
    if ($devMgrStartupCreated -and (Test-Path -LiteralPath $devMgrStartup)) {
        try {
            Remove-Item -LiteralPath $devMgrStartup
        } catch {$rollback += $_.Exception.Message}
    }
    if ($buttonsStartupCreated -and (Test-Path -LiteralPath $buttonsStartup)) {
        try {
            Remove-Item -LiteralPath $buttonsStartup
        } catch {$rollback += $_.Exception.Message}
    }
    if ($verifiedDisk) {try {Flush-Dismount} catch {$rollback += $_.Exception.Message}}
    if ($receiptWritable) {
        [ordered]@{phase='failed';error=$failure;rollback_errors=$rollback;trial_bundle_retained_unarmed=$true;
            archived_leftovers=$archived;utc=[DateTime]::UtcNow.ToString('o')} |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')
    }
    throw
}
