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
    return $manifest
}

function Get-TouchGpioDevice([string]$Id) {
    # Do not synthesize a registry instance from a friendly name or substring.
    $devices = @(Get-CimInstance Win32_PnPEntity | Where-Object {$_.PNPDeviceID -ieq $Id})
    if ($devices.Count -ne 1) {throw "Expected exactly one device: $Id"}
    return $devices[0]
}
