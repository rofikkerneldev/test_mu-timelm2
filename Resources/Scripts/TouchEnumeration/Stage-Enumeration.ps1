# Run elevated on the PC while the known V60 is in Mu Mass Storage.
param([Parameter(Mandatory=$true)][string]$Artifact,
      [Parameter(Mandatory=$true)][string]$Output,
      [switch]$HostLoadTrial,
      [string]$HostPackage)
$ErrorActionPreference = 'Stop'
$modified = New-Object 'System.Collections.Generic.List[string]'
$startupCreated = $false
$original = $null
function Write-Flushed([string]$Path, [byte[]]$Data) {
    $f = [IO.FileStream]::new($Path,[IO.FileMode]::Create,[IO.FileAccess]::Write,
        [IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
    try {$f.Write($Data,0,$Data.Length);$f.Flush($true)} finally {$f.Dispose()}
}
function Copy-Verified([string]$From, [string]$To) {
    Copy-Item -LiteralPath $From -Destination $To
    $hash = (Get-FileHash -LiteralPath $From).Hash
    if ((Get-FileHash -LiteralPath $To).Hash -ne $hash) {throw "Copy verification failed: $To"}
    return $hash
}
try {
    if (!(Test-Path -LiteralPath $Output -PathType Container)) {throw 'Precreate the PC receipt directory'}
    if (Test-Path -LiteralPath (Join-Path $Output 'stage-status.json')) {throw 'Stage already attempted; inspect receipt'}
    $meta = Get-Content -LiteralPath (Join-Path $Artifact 'touch-enumeration.json') -Raw | ConvertFrom-Json
    $launcher = Join-Path $Artifact 'TouchEnumerationOnce.efi'
    if ((Get-FileHash -LiteralPath $launcher).Hash -ne $meta.sha256 -or
        $meta.smmu_access -ne $false -or $meta.iort_installed -ne $false -or
        $meta.restores_windows_first -ne $true -or $meta.requires_no_matching_drivers -ne $true) {throw 'Wrong trial artifact'}
    $disks = @(Get-Disk | Where-Object {$_.BusType -eq 'USB' -and $_.SerialNumber.Trim() -eq '8509C01F'})
    if ($disks.Count -ne 1 -or $disks[0].Size -ne 126374379520 -or $disks[0].IsBoot -or $disks[0].IsSystem) {throw 'V60 disk mismatch'}
    $win = Get-Partition -DiskNumber $disks[0].Number -PartitionNumber 30
    $esp = Get-Partition -DiskNumber $disks[0].Number -PartitionNumber 29
    if ($win.Offset -ne 62719688704 -or $win.Size -ne 42949672960 -or !$win.DriveLetter -or
        $esp.Offset -ne 62182817792 -or $esp.Size -ne 536870912 -or
        $esp.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') {throw 'V60 partition mismatch'}
    $winRoot = [string]$win.DriveLetter + ':\'
    $espRoot = @($esp.AccessPaths | Where-Object {$_ -like '\\?\Volume*'})[0]
    if (!$espRoot) {throw 'ESP path unavailable'}
    if ((Get-Content -LiteralPath (Join-Path $winRoot 'TimelmTools\OobeHelper\timelm-device.marker') -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') {throw 'Wrong installation marker'}
    $infs = @(Get-ChildItem -LiteralPath (Join-Path $winRoot 'Windows\INF') -Filter '*.inf' -File)
    if ($infs.Count -lt 100) {throw 'Incomplete Windows INF enumeration'}
    $matches = @($infs | Select-String -Pattern 'TIML0001|LGSW4290' -List)
    $replaces = $null
    if ($HostLoadTrial) {
        $replaces = @((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'HostLoadPackage.json') -Raw | ConvertFrom-Json).replaces_inf_sha256)
    }
    foreach ($match in $matches) {
        if (!$replaces -or (Get-FileHash -LiteralPath $match.Path).Hash -notin $replaces) {throw 'Matching touch/host driver is installed; enumeration-only precondition failed'}
    }
    foreach ($driver in @('kona_geni.sys','vhidmini.sys')) {
        if (Test-Path -LiteralPath (Join-Path $winRoot ('Windows\System32\drivers\'+$driver))) {throw 'Unexpected experimental driver binary installed'}
    }
    $probeName = if ($HostLoadTrial) {'TouchHostLoadProbe'} else {'TouchEnumerationProbe'}
    $runnerName = if ($HostLoadTrial) {'Run-HostLoadProbe.ps1'} else {'Run-EnumerationProbe.ps1'}
    $startupName = if ($HostLoadTrial) {'Timelm-touch-host-load.cmd'} else {'Timelm-touch-enumeration.cmd'}
    $bundle = Join-Path $winRoot ('TimelmTools\'+$probeName)
    $logs = Join-Path $winRoot ('TimelmLogs\'+$probeName)
    $startup = Join-Path $winRoot ('ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\'+$startupName)
    if ((Test-Path -LiteralPath $bundle) -or (Test-Path -LiteralPath $logs) -or (Test-Path -LiteralPath $startup)) {throw 'Enumeration probe already exists; do not rearm blindly'}
    if ($HostLoadTrial) {
        if (!$HostPackage) {throw 'Host package path required'}
        $package = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'HostLoadPackage.json') -Raw | ConvertFrom-Json
        if (@($package.files).Count -ne 4) {throw 'Unexpected package manifest'}
        foreach ($file in $package.files) {
            if ($file.name -notin @('kona_geni.inf','kona_geni.sys','kona_geni.cat','kona_geni.cer')) {throw 'Unexpected host package file'}
            $src = Join-Path $HostPackage $file.name
            if ((Get-Item -LiteralPath $src).Length -ne $file.size -or (Get-FileHash -LiteralPath $src).Hash -ne $file.sha256) {throw 'Pinned host package mismatch'}
        }
    }
    $targets = @('EFI\Microsoft\Boot\bootmgfw.efi','EFI\Boot\bootaa64.efi')
    $backups = @('EFI\Microsoft\Boot\bootmgfw.timelm-i2c-original.efi','EFI\Boot\bootaa64.timelm-i2c-original.efi')
    foreach ($rel in $targets) {
        $src = $espRoot + $rel
        if ((Get-Item -LiteralPath $src).Length -ne $meta.windows_reference.size -or
            (Get-FileHash -LiteralPath $src).Hash -ne $meta.windows_reference.sha256) {throw 'Windows boot manager reference mismatch'}
        $dest = Join-Path $Output ('before\' + $rel)
        $null = New-Item -ItemType Directory -Path (Split-Path $dest) -Force
        $null = Copy-Verified $src $dest
    }
    $bcd = $espRoot + 'EFI\Microsoft\Boot\BCD'
    $bcdHash = Copy-Verified $bcd (Join-Path $Output 'BCD-before-enumeration')
    $original = [IO.File]::ReadAllBytes((Join-Path $Output ('before\'+$targets[0])))
    foreach ($rel in $backups) {
        $dest = $espRoot + $rel
        if (Test-Path -LiteralPath $dest) {
            if ((Get-FileHash -LiteralPath $dest).Hash -ne $meta.windows_reference.sha256) {throw 'Stale original EFI backup; inspect manually'}
        } else { Write-Flushed $dest $original }
        if ((Get-FileHash -LiteralPath $dest).Hash -ne $meta.windows_reference.sha256) {throw 'Original EFI backup readback failed'}
    }
    $null = New-Item -ItemType Directory -Path $bundle
    $sources = @((Join-Path $PSScriptRoot $runnerName),
        (Join-Path $PSScriptRoot 'Invoke-ProbeProcess.ps1'),
        (Join-Path $PSScriptRoot $startupName),
        (Join-Path (Split-Path $PSScriptRoot) 'Collect-TimelmDiagnostics.ps1'))
    if ($HostLoadTrial) {$sources += Join-Path $PSScriptRoot 'HostLoadPackage.json'}
    $hashes = foreach ($source in $sources) {
        $hash = Copy-Verified $source (Join-Path $bundle (Split-Path $source -Leaf))
        [ordered]@{file=(Split-Path $source -Leaf);sha256=$hash}
    }
    if ($HostLoadTrial) {
        $packageDest = Join-Path $bundle 'HostPackage'
        $null = New-Item -ItemType Directory -Path $packageDest
        foreach ($file in $package.files) {
            $hash = Copy-Verified (Join-Path $HostPackage $file.name) (Join-Path $packageDest $file.name)
            $hashes += [ordered]@{file=('HostPackage\'+$file.name);sha256=$hash}
        }
        $clockPath = Join-Path $bundle 'host-utc.txt'
        [DateTime]::UtcNow.ToString('o') | Set-Content -LiteralPath $clockPath
        $hashes += [ordered]@{file='host-utc.txt';sha256=(Get-FileHash -LiteralPath $clockPath).Hash}
    }
    # Arm only after both immutable EFI restoration files are verified.
    $startupCreated = $true
    $null = Copy-Verified (Join-Path $bundle $startupName) $startup
    $newData = [IO.File]::ReadAllBytes($launcher)
    foreach ($rel in $targets) {
        $dest = $espRoot + $rel
        $modified.Add($dest)
        Write-Flushed $dest $newData
        if ((Get-FileHash -LiteralPath $dest).Hash -ne $meta.sha256) {throw 'Launcher readback failed'}
    }
    if ((Get-FileHash -LiteralPath $bcd).Hash -ne $bcdHash) {throw 'BCD changed during staging'}
    Write-VolumeCache -DriveLetter $win.DriveLetter
    $esp | Get-Volume | Write-VolumeCache
    & fsutil.exe volume dismount ($winRoot.TrimEnd('\')) *> (Join-Path $Output 'win-dismount.txt')
    if ($LASTEXITCODE -ne 0) {throw 'Windows dismount failed'}
    & fsutil.exe volume dismount ($espRoot.TrimEnd('\')) *> (Join-Path $Output 'esp-dismount.txt')
    if ($LASTEXITCODE -ne 0) {throw 'ESP dismount failed'}
    [ordered]@{phase='ready-for-one-boot-enumeration';utc=[DateTime]::UtcNow.ToString('o');
        launcher=$meta;helper_files=$hashes;checked_installed_infs=$infs.Count;
        runtime_host_install_planned=[bool]$HostLoadTrial;probe=$probeName;
        driver_changes=$false;bcd_before_after=$bcdHash;iort_installed=$false;
        boot_partition_flashed=$false;flushed_and_dismounted=$true;serial='8509C01F'} |
        ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $Output 'stage-status.json')
} catch {
    $failure = $_.Exception.Message
    $rollback = @()
    foreach ($dest in $modified) {
        try {
            Write-Flushed $dest $original
            if ((Get-FileHash -LiteralPath $dest).Hash -ne $meta.windows_reference.sha256) {throw 'Rollback hash mismatch'}
        } catch {$rollback += $_.Exception.Message}
    }
    if ($startupCreated -and (Test-Path -LiteralPath $startup)) {
        try {Remove-Item -LiteralPath $startup} catch {$rollback += $_.Exception.Message}
    }
    [ordered]@{phase='failed';error=$failure;rollback_errors=$rollback;utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Output 'stage-status.json')
    throw
}
