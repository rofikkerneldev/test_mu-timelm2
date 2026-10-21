# PC-side assembly of the verified one-boot GPIO touch trial bundle.
# Reads built driver packages, the trial EFI/SSDT and the phone's installed
# INF set. It never writes to the phone, never installs a driver and never
# touches the EFI partition.
param(
    [Parameter(Mandatory=$true)][string]$GpioPackage,
    [Parameter(Mandatory=$true)][string]$HostPackage,
    [Parameter(Mandatory=$true)][string]$TouchPackage,
    [Parameter(Mandatory=$true)][string]$Trial,
    [Parameter(Mandatory=$true)][string]$Output,
    [string]$InstalledInfFolder,
    [string]$Receipt
)
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {throw 'Build the bundle on the x64 PC, not the phone'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
$expectedWindowsHash = 'fae47d78487e781aa06466775cb461adeb7ff7f887fe2c15295bb2eb4f4954e1'
$expectedWindowsSize = 3120648
function Resolve-Directory([string]$Path, [string]$Label) {
    if (!(Test-Path -LiteralPath $Path -PathType Container)) {throw "Missing $Label directory: $Path"}
    $item = Get-Item -LiteralPath $Path
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw "Reparse point is not a build output: $Path"}
    return $item.FullName
}
function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-Arm64Efi([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {throw 'Trial launcher is not a PE image'}
    $offset = [BitConverter]::ToUInt32($bytes,0x3c)
    if ($offset -gt $bytes.Length-96 -or [BitConverter]::ToUInt32($bytes,$offset) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes,$offset+4) -ne 0xaa64 -or
        [BitConverter]::ToUInt16($bytes,$offset+92) -ne 10) {throw 'Trial launcher must be an ARM64 EFI application'}
}
try {
    if (Test-Path -LiteralPath $Output) {throw 'Refusing to overwrite an existing bundle directory'}
    $created = $false
    $trialRoot = Resolve-Directory $Trial 'trial'
    $sources = @(
        @{name='GPIO';root=(Resolve-Directory $GpioPackage 'GPIO package');base='GPIO';catalog='GPIO.cat';id='KONA1001'},
        @{name='Host';root=(Resolve-Directory $HostPackage 'host package');base='kona_geni';catalog='kona_geni.cat';id='TIML0001'},
        @{name='Touch';root=(Resolve-Directory $TouchPackage 'touch package');base='vhidmini';catalog='sw42902.cat';id='LGSW4290'}
    )
    # Validate the trial launcher and SSDT first. The staging script checks the
    # same fields, so a bundle that passes here is provably stageable.
    $launcher = Join-Path $trialRoot 'TouchGpioOnce.efi'
    $ssdt = Join-Path $trialRoot 'TouchGpio.aml'
    $meta = Get-Content -LiteralPath (Join-Path $trialRoot 'touch-gpio.json') -Raw | ConvertFrom-Json
    if (!(Test-Path -LiteralPath $launcher) -or !(Test-Path -LiteralPath $ssdt)) {throw 'Trial launcher or SSDT missing'}
    Assert-Arm64Efi $launcher
    if ($meta.sha256 -notmatch '^[0-9a-fA-F]{64}$' -or (Get-Sha256 $launcher) -ne $meta.sha256.ToLowerInvariant() -or
        $meta.ssdt_sha256 -notmatch '^[0-9a-fA-F]{64}$' -or (Get-Sha256 $ssdt) -ne $meta.ssdt_sha256.ToLowerInvariant()) {throw 'Trial launcher or SSDT does not match its metadata'}
    if ($meta.restores_windows_first -ne $true -or $meta.iort_installed -ne $false -or $meta.smmu_access -ne $false -or
        $meta.bbtrial -ne $true -or $meta.windows_reference.size -ne $expectedWindowsSize -or
        $meta.windows_reference.sha256 -ine $expectedWindowsHash) {throw 'Trial metadata does not describe a restore-first GPIO-only trial'}
    $installedRoot = $null
    if ($InstalledInfFolder) {
        $installedRoot = Resolve-Directory $InstalledInfFolder 'installed INF folder'
        if (!(Get-ChildItem -LiteralPath $installedRoot -Filter '*.inf' -File).Count) {throw 'Installed INF folder is empty'}
    }
    $null = New-Item -ItemType Directory -Path $Output
    $created = $true
    $files = New-Object 'System.Collections.Generic.List[object]'
    $packages = New-Object 'System.Collections.Generic.List[object]'
    foreach ($source in $sources) {
        $inf = Join-Path $source.root ($source.base+'.inf')
        $catalog = Join-Path $source.root $source.catalog
        $sys = Join-Path $source.root ($source.base+'.sys')
        foreach ($required in @($inf,$catalog,$sys)) {
            if (!(Test-Path -LiteralPath $required -PathType Leaf)) {throw "Missing $($source.name) package file: $required"}
        }
        # The hardware ID and catalog must match the manifest identity, so a
        # swapped or unrelated package can never enter the trial bundle.
        $infText = Get-Content -LiteralPath $inf -Raw
        $declared = [regex]::Match($infText, '(?im)^CatalogFile\s*=\s*([^;\s]+)\s*$')
        if (!$declared.Success -or $declared.Groups[1].Value -ine $source.catalog) {throw "Catalog mismatch in $($source.name) INF"}
        $models = @([regex]::Matches($infText, '(?im)^[^;\r\n]*=\s*[^,\r\n]+,\s*ACPI\\([A-Z0-9]+)(?:\s|$)'))
        if ($models.Count -ne 1 -or $models[0].Groups[1].Value -ne $source.id) {throw "Wrong hardware ID in $($source.name) INF"}
        $certificate = Join-Path $source.root ($source.base+'.cer')
        if (!(Test-Path -LiteralPath $certificate -PathType Leaf)) {
            # CI packages carry no certificate file; take the signer of the
            # signed driver so the phone can trust the package later.
            $signed = Get-AuthenticodeSignature -LiteralPath $sys
            if (!$signed.SignerCertificate) {throw "No signer certificate for $($source.name) driver"}
            [IO.File]::WriteAllBytes($certificate,$signed.SignerCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
        }
        $thumbprint = (New-Object Security.Cryptography.X509Certificates.X509Certificate2($certificate)).Thumbprint
        $destination = Join-Path $Output ('Drivers/'+$source.name)
        $null = New-Item -ItemType Directory -Path $destination -Force
        $leaves = @(($source.base+'.inf'),$source.catalog,($source.base+'.sys'),($source.base+'.cer'))
        foreach ($leaf in $leaves) {
            $from = Join-Path $source.root $leaf
            $to = Join-Path $destination $leaf
            Copy-Item -LiteralPath $from -Destination $to
            if ((Get-Sha256 $to) -ne (Get-Sha256 $from)) {throw "Copy verification failed: $leaf"}
            $files.Add([ordered]@{path=('Drivers/'+$source.name+'/'+$leaf);size=(Get-Item -LiteralPath $to).Length;sha256=(Get-Sha256 $to)})
        }
        # Every installed INF that matches this hardware ID must be listed, or
        # the staging script refuses the trial as an unreviewed replacement.
        $replaces = @()
        if ($installedRoot) {
            $pattern = 'ACPI\\'+$source.id
            foreach ($match in @(Get-ChildItem -LiteralPath $installedRoot -Filter '*.inf' -File | Select-String -Pattern $pattern -List)) {
                $hash = Get-Sha256 $match.Path
                if ($hash -ne (Get-Sha256 $inf)) {$replaces += $hash}
            }
        }
        $packages.Add([ordered]@{name=$source.name;inf=($source.base+'.inf');catalog=$source.catalog;
            certificate=($source.base+'.cer');certificate_thumbprint=$thumbprint;replaces_inf_sha256=@($replaces)})
    }
    foreach ($file in @(@{from=$launcher;to='TouchGpioOnce.efi'},@{from=$ssdt;to='TouchGpio.aml'},@{from=(Join-Path $trialRoot 'touch-gpio.json');to='touch-gpio.json'})) {
        $to = Join-Path $Output $file.to
        Copy-Item -LiteralPath $file.from -Destination $to
        if ((Get-Sha256 $to) -ne (Get-Sha256 $file.from)) {throw "Copy verification failed: $($file.to)"}
    }
    $manifest = [ordered]@{
        schema = 1
        trial = 'touch-gpio-v1'
        source_commit = [string]$meta.commit
        ssdt_sha256 = $meta.ssdt_sha256.ToLowerInvariant()
        files = @($files.ToArray())
        packages = @($packages.ToArray())
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Output 'package.json')
    # Reuse the runtime manifest check so the bundle cannot differ from what
    # the phone bootstrap will accept.
    $null = Get-TouchGpioManifest $Output
    if ($Receipt) {
        $installedCount = 0
        if ($installedRoot) {$installedCount = @(Get-ChildItem -LiteralPath $installedRoot -Filter '*.inf' -File).Count}
        [ordered]@{built_utc=[DateTime]::UtcNow.ToString('o');bundle=$Output;trial=$meta.commit;
            ssdt_sha256=$manifest.ssdt_sha256;packages=$manifest.packages;
            installed_inf_folder=if ($installedRoot) {$installedRoot} else {'not supplied'};
            installed_inf_count=$installedCount} |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Receipt
    }
    Write-Host ("Bundle verified: {0} ({1} files, {2} packages)" -f $Output,$manifest.files.Count,$manifest.packages.Count)
} catch {
    # Only remove a directory this run created; a refused output must stay.
    if ($created -and (Test-Path -LiteralPath $Output)) {Remove-Item -LiteralPath $Output -Recurse -Force}
    throw
}
