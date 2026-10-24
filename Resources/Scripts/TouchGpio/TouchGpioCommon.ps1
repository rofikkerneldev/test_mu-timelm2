# Shared read-only validation. Importing this file does not change the machine.
function Get-SharedSha256([Parameter(Mandatory=$true)][string]$LiteralPath, [string]$Algorithm = 'SHA256') {
    # The same sharing flags the real Get-FileHash uses (ReadWrite + Delete):
    # a phone hive or an ESP artifact can still be held for a moment when a
    # scanner noticed the write, and a reader that only shares read would
    # break the trial there. Retry briefly instead of failing the stage.
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            $share = [IO.FileShare]([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $stream = New-Object IO.FileStream($LiteralPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
            try {
                $hash = [Security.Cryptography.HashAlgorithm]::Create($Algorithm)
                try {
                    return [pscustomobject]@{Path=$LiteralPath;Algorithm=$Algorithm;
                        Hash=([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','')}
                } finally {$hash.Dispose()}
            } finally {$stream.Dispose()}
        } catch {
            # MethodInvocationException-style wrapping hides the sharing
            # violation; retry only when the base exception really is one.
            if ($attempt -eq 8) {throw}
            if (!($_.Exception.GetBaseException() -is [System.IO.IOException])) {throw}
            Start-Sleep -Milliseconds 250
        }
    }
}
if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
    # Some trimmed Windows PowerShell installs ship the utility module without
    # Get-FileHash. Compute SHA-256 directly so the trial never depends on it.
    function Get-FileHash {
        param([Parameter(Mandatory=$true)][string]$LiteralPath, [string]$Algorithm = 'SHA256')
        return Get-SharedSha256 -LiteralPath $LiteralPath -Algorithm $Algorithm
    }
}
function Get-TouchGpioManifest([string]$Root) {
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'package.json') -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.trial -ne 'touch-gpio-v1' -or
        $manifest.ssdt_sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        @($manifest.files).Count -ne 12 -or @($manifest.packages).Count -ne 3) {throw 'Invalid touch GPIO package manifest'}
    $expected = @{GPIO='GPIO';Host='kona_geni';Touch='vhidmini'}
    $catalogs = @{GPIO='GPIO.cat';Host='kona_geni.cat';Touch='sw42902.cat'}
    $ids = @{GPIO='KONA1001';Host='TIML0001';Touch='LGSW4290'}
    $seenPackages = @{}; $seenFiles = @{}
    foreach ($p in $manifest.packages) {
        if ($p.name -notin @('GPIO','Host','Touch') -or $seenPackages.ContainsKey([string]$p.name)) {throw 'Unexpected or duplicate driver package'}
        $seenPackages[[string]$p.name] = $true
        $base = $expected[[string]$p.name]
        if ($p.inf -ne ($base+'.inf') -or $p.catalog -ine $catalogs[[string]$p.name] -or $p.certificate -ne ($base+'.cer') -or
            $p.certificate_thumbprint -notmatch '^[0-9a-fA-F]{40}$') {throw 'Unexpected driver package identity'}
        foreach ($hash in @($p.replaces_inf_sha256)) {
            if ($hash -and $hash -notmatch '^[0-9a-fA-F]{64}$') {throw 'Invalid replacement INF hash'}
        }
        foreach ($extension in @('inf','cat','sys','cer')) {
            $leaf = if ($extension -eq 'cat') {$p.catalog} else {$base+'.'+$extension}
            $relative = 'Drivers/'+$p.name+'/'+$leaf
            $entries = @($manifest.files | Where-Object {$_.path -ceq $relative})
            if ($entries.Count -ne 1 -or $seenFiles.ContainsKey($relative)) {throw "Manifest file missing or duplicated: $relative"}
            $seenFiles[$relative] = $true
            $entry = $entries[0]
            if ($entry.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or $entry.size -le 0) {throw 'Invalid package hash/size'}
            $path = Join-Path $Root $relative
            $item = Get-Item -LiteralPath $path
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                $item.Length -ne $entry.size -or (Get-FileHash -LiteralPath $path).Hash -ne $entry.sha256) {throw "Package verification failed: $relative"}
        }
        $inf = Get-Content -LiteralPath (Join-Path $Root ('Drivers/'+$p.name+'/'+$p.inf)) -Raw
        $catalog = [regex]::Match($inf, '(?im)^CatalogFile\s*=\s*([^;\s]+)\s*$')
        if (!$catalog.Success -or $catalog.Groups[1].Value -ine $p.catalog) {throw 'Catalog manifest does not match the INF'}
        $models = @([regex]::Matches($inf, '(?im)^[^;\r\n]*=\s*[^,\r\n]+,\s*ACPI\\([A-Z0-9]+)(?:\s|$)'))
        if ($models.Count -ne 1 -or $models[0].Groups[1].Value -ne $ids[[string]$p.name]) {throw "Wrong INF hardware ID: $($p.name)"}
        if ($p.name -eq 'Host') {
            foreach ($gate in @('NativeBoardInitEnabled','NativeGpiEnabled','WindowsIommuEnabled','FirmwareHandoffVerified','SourceClockHz','ReadOnlyHardwareProbeEnabled','NativeGpioI2cEnabled')) {
                if ($inf -notmatch ('(?im)^HKR\s*,\s*,\s*'+$gate+'\s*,\s*0x00010001\s*,\s*0\s*$')) {throw "Host gate must default to zero: $gate"}
            }
            if ($inf -notmatch '(?im)^StartType\s*=\s*3\s*$') {throw 'Host service must be demand-start'}
        }
        $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2((Join-Path $Root ('Drivers/'+$p.name+'/'+$p.certificate)))
        try {if ($certificate.Thumbprint -ne $p.certificate_thumbprint) {throw 'Certificate thumbprint mismatch'}} finally {$certificate.Reset()}
    }
    if ($seenFiles.Count -ne @($manifest.files).Count) {throw 'Unexpected package paths'}
    if($manifest.revision -eq 2) {
        if($manifest.diagnostic_build_id -ne 539365412 -or $manifest.provenance_sha256 -notmatch '^[a-f0-9]{64}$' -or
            (Get-FileHash -LiteralPath (Join-Path $Root 'provenance.json')).Hash -ine $manifest.provenance_sha256) {throw 'Trial source provenance mismatch'}
        if(@($manifest.helpers).Count -lt 10){throw 'Trial helper manifest incomplete'}
        $helperPaths=@{}
        foreach($helper in $manifest.helpers) {
            if($helper.path -notmatch '^[A-Za-z0-9-]+\.(ps1|cmd)$' -or $helperPaths.ContainsKey($helper.path) -or
                $helper.sha256 -notmatch '^[a-f0-9]{64}$' -or
                (Get-FileHash -LiteralPath (Join-Path $Root $helper.path)).Hash -ine $helper.sha256) {throw 'Trial helper integrity mismatch'}
            $helperPaths[$helper.path]=$true
        }
    }
    return $manifest
}

function Get-TouchGpioDevice([string]$Id) {
    # Do not synthesize a registry instance from a friendly name or substring.
    $devices = @(Get-CimInstance Win32_PnPEntity | Where-Object {$_.PNPDeviceID -ieq $Id})
    if ($devices.Count -ne 1) {throw "Expected exactly one device: $Id"}
    return $devices[0]
}

function Write-TouchGpioJson([string]$Path, $Value) {
    # Publish only after flush, readback and JSON validation. A temporary file
    # from an interrupted write is not a committed phase receipt.
    $full = [IO.Path]::GetFullPath($Path)
    $temp = $full + '.' + [guid]::NewGuid().ToString('N') + '.pending'
    $text = ConvertTo-Json -InputObject $Value -Depth 16
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
    $stream = [IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,
        [IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
    try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
    $read = [IO.File]::ReadAllText($temp)
    $null = ConvertFrom-Json -InputObject $read -ErrorAction Stop
    if ($read -cne $text) {throw 'JSON readback mismatch'}
    if ([IO.File]::Exists($full)) {[IO.File]::Replace($temp,$full,[NullString]::Value)}
    else {[IO.File]::Move($temp,$full)}
}
function Get-TouchGpioHelperSources([string]$Root) {
    $files=@(Get-ChildItem -LiteralPath $Root -File | Where-Object {$_.Extension -in @('.ps1','.cmd')})
    $files+=@((Get-Item (Join-Path $Root '../Collect-TimelmDiagnostics.ps1')),
        (Get-Item (Join-Path $Root '../TouchEnumeration/Invoke-ProbeProcess.ps1')))
    $names=@{}
    foreach($file in $files) {
        if($names.ContainsKey($file.Name)){throw 'Duplicate helper source name'}
        $names[$file.Name]=$true
    }
    return $files
}
function Add-TouchGpioEvent([string]$Path, $Value) {
    $line = (ConvertTo-Json -InputObject $Value -Depth 8 -Compress) + "`r`n"
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($line)
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,
        [IO.FileShare]::Read,4096,[IO.FileOptions]::WriteThrough)
    try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
}
function ConvertFrom-TouchGpioRegQuery([string[]]$Lines) {
    $values = @{}
    foreach ($line in $Lines) {
        if ($line -match '^\s+([^\s]+)\s+REG_(?:SZ|EXPAND_SZ|DWORD)\s+(.*)$') {
            $values[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $values
}
function Get-TouchGpioSelectedPackage {
    param([string]$RegistryRoot,[string]$ControlSet,[string]$DeviceId,[string]$WindowsRoot,
          [string]$InfHash,[string]$SysHash,[string]$Service,[scriptblock]$Query,[switch]$FilterService)
    $result = [ordered]@{matches=$false;driver='';node='';inf='';inf_path='';inf_sha256='';
        service='';image_path='';sys_path='';sys_sha256='';reason='binding absent'}
    if (!$Query) {
        $Query = {param($Key)
            $preference=$ErrorActionPreference;$ErrorActionPreference='Continue'
            try {$lines = & reg.exe query $Key 2>$null;$code=$LASTEXITCODE}
            finally {$ErrorActionPreference=$preference}
            if($code -ne 0){throw 'Registry query failed'}
            return $lines
        }
    }
    try {
        $enum = ConvertFrom-TouchGpioRegQuery @(& $Query ($RegistryRoot+'\'+$ControlSet+'\Enum\'+$DeviceId))
        $driver = [string]$enum['Driver'];$result.driver=$driver
        if ($driver -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\\[0-9a-fA-F]{4}$') {
            $result.reason='invalid or missing Enum Driver';return $result
        }
        $result.node=$driver
        $class = ConvertFrom-TouchGpioRegQuery @(& $Query ($RegistryRoot+'\'+$ControlSet+'\Control\Class\'+$driver))
        $name = [string]$class['InfPath']
        if ($name -notmatch '^oem[0-9]+\.inf$' -or $class['MatchingDeviceId'] -ine ($DeviceId -replace '\\[^\\]+$','')) {
            $result.reason='selected class identity missing or foreign';return $result
        }
        $result.inf=$name;$result.inf_path=Join-Path $WindowsRoot ('Windows\INF\'+$name)
        $result.inf_sha256=(Get-FileHash -LiteralPath $result.inf_path).Hash.ToLowerInvariant()
        $result.service=[string]$enum['Service']
        if ($FilterService) {
            $infText=Get-Content -LiteralPath $result.inf_path -Raw
            if($infText -notmatch ('(?im)^AddFilter\s*=\s*'+[regex]::Escape($Service)+'\s*,') -or
                $infText -notmatch '(?im)^FilterPosition\s*=\s*Lower\s*$') {$result.reason='selected lower-filter contract missing';return $result}
        } elseif ($result.service -ine $Service) {$result.reason='selected service mismatch';return $result}
        $svc = ConvertFrom-TouchGpioRegQuery @(& $Query ($RegistryRoot+'\'+$ControlSet+'\Services\'+$Service))
        $image=[string]$svc['ImagePath'];$result.image_path=$image
        $relative=$image -replace '^\\SystemRoot\\','' -replace '^%SystemRoot%\\',''
        if ($relative -notmatch '^System32\\DriverStore\\FileRepository\\[^\\]+\\[^\\]+\.sys$') {
            $result.reason='unexpected selected service ImagePath';return $result
        }
        $result.sys_path=Join-Path $WindowsRoot ('Windows\'+$relative)
        $result.sys_sha256=(Get-FileHash -LiteralPath $result.sys_path).Hash.ToLowerInvariant()
        $result.matches=($result.inf_sha256 -ieq $InfHash -and $result.sys_sha256 -ieq $SysHash)
        $result.reason=if($result.matches){'exact Enum/Class/service binary match'}else{'selected package hash mismatch'}
    } catch {$result.matches=$false;$result.reason=$_.Exception.Message}
    return $result
}
function Assert-TouchGpioProviderGate($Requested, $Effective) {
    if ($null -eq $Requested -or $Requested -ne 1 -or $null -eq $Effective -or $Effective -ne 1) {
        throw 'Provider readiness requires requested and effective gate exactly 1'
    }
}
function Assert-TouchGpioHostEvidence($Parameters, [uint32]$AttemptId, [uint32]$BuildId) {
    if (!$Parameters -or !$AttemptId -or $Parameters.TimelmBitbangAttempt -ne $AttemptId -or
        $Parameters.TimelmBitbangBuildId -ne $BuildId -or $Parameters.TimelmHostBuildId -ne $BuildId -or
        $Parameters.TimelmHostBackend -ne 1 -or $Parameters.TimelmBitbangSchema -ne 2 -or
        $Parameters.TimelmBitbangSnapshotValid -ne 1 -or $Parameters.TimelmBitbangStage -ne 4 -or
        $Parameters.TimelmBitbangStatus -ne 0 -or $Parameters.TimelmBitbangProviderGate -ne 1 -or
        $Parameters.TimelmBitbangProviderStatus -ne 0 -or
        ($Parameters.TimelmBitbangEpochLow -eq 0 -and $Parameters.TimelmBitbangEpochHigh -eq 0) -or
        $null -eq $Parameters.TimelmBitbangEpochLow -or $null -eq $Parameters.TimelmBitbangEpochHigh -or
        $null -eq $Parameters.TimelmBitbangProviderEpochLow -or $null -eq $Parameters.TimelmBitbangProviderEpochHigh -or
        ($Parameters.TimelmBitbangProviderEpochLow -eq 0 -and $Parameters.TimelmBitbangProviderEpochHigh -eq 0)) {
        throw 'Fresh matching attempt/build/backend/provider identity evidence is required'
    }
}
