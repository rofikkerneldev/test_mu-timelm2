# Synthetic package builder checks on the build PC. No phone, no real driver.
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {throw 'Run this check on the x64 PC'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
$builder = Join-Path $PSScriptRoot 'Build-TouchGpioPackage.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('timelm-touch-gpio-'+[Guid]::NewGuid().ToString('N'))
function New-TestCertificate([string]$Path) {
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $request = New-Object Security.Cryptography.X509Certificates.CertificateRequest(
            'CN=timelm touch gpio package test',$rsa,'SHA256',
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add((New-Object Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($false,$false,0,$true)))
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1),[DateTimeOffset]::UtcNow.AddDays(365))
        [IO.File]::WriteAllBytes($Path,$certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    } finally {$rsa.Dispose()}
}
function New-TestPackage([string]$Path, [string]$Base, [string]$Catalog, [string]$DeclaredCatalog, [string]$Id, [string]$Gates) {
    $null = New-Item -ItemType Directory -Path $Path -Force
    $inf = "[Version]`r`nSignature=`"`$WINDOWS NT$`"`r`nClass=System`r`nCatalogFile=$DeclaredCatalog`r`n[Manufacturer]`r`n%Provider%=Devices,ACPI\$Id`r`n"
    if ($Gates) {
        $inf += "[Device]`r`nAddReg=Gates`r`n[Gates]`r`n"
        foreach ($gate in $Gates.Split(',')) {$inf += "HKR,,$gate,0x00010001,0`r`n"}
        $inf += "[Service]`r`nStartType = 3`r`n"
    }
    [IO.File]::WriteAllText((Join-Path $Path ($Base+'.inf')),$inf)
    [IO.File]::WriteAllBytes((Join-Path $Path $Catalog),[byte[]](1..64))
    [IO.File]::WriteAllBytes((Join-Path $Path ($Base+'.sys')),[byte[]](65..128))
    New-TestCertificate (Join-Path $Path ($Base+'.cer'))
}
function New-TestTrial([string]$Path) {
    $null = New-Item -ItemType Directory -Path $Path -Force
    # Minimal ARM64 EFI application header, matching the staging check.
    $bytes = New-Object byte[] 512
    $bytes[0] = 0x4d; $bytes[1] = 0x5a
    [BitConverter]::GetBytes([uint32]0x80).CopyTo($bytes,0x3c)
    [BitConverter]::GetBytes([uint32]0x4550).CopyTo($bytes,0x80)
    [BitConverter]::GetBytes([uint16]0xaa64).CopyTo($bytes,0x84)
    [BitConverter]::GetBytes([uint16]10).CopyTo($bytes,0x80+92)
    [IO.File]::WriteAllBytes((Join-Path $Path 'TouchGpioOnce.efi'),$bytes)
    [IO.File]::WriteAllBytes((Join-Path $Path 'TouchGpio.aml'),[byte[]](129..192))
    $meta = [ordered]@{
        commit = '0' * 40
        sha256 = (Get-FileHash -LiteralPath (Join-Path $Path 'TouchGpioOnce.efi') -Algorithm SHA256).Hash.ToLowerInvariant()
        ssdt_sha256 = (Get-FileHash -LiteralPath (Join-Path $Path 'TouchGpio.aml') -Algorithm SHA256).Hash.ToLowerInvariant()
        restores_windows_first = $true
        iort_installed = $false
        smmu_access = $false
        bbtrial = $true
        windows_reference = [ordered]@{size = 3120648; sha256 = 'fae47d78487e781aa06466775cb461adeb7ff7f887fe2c15295bb2eb4f4954e1'}
    }
    $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Path 'touch-gpio.json')
}
function Expect-Rejection([string]$Label, [scriptblock]$Action, [string]$Expected) {
    $rejected = $false
    try {&$Action} catch {if ($_.Exception.Message -notlike "*$Expected*") {throw "$Label failed for an unexpected reason: $($_.Exception.Message)"}; $rejected = $true}
    if (!$rejected) {throw "$Label was not rejected"}
}
try {
    New-TestPackage (Join-Path $root 'gpio') 'GPIO' 'GPIO.cat' 'GPIO.cat' 'KONA1001' ''
    New-TestPackage (Join-Path $root 'host') 'kona_geni' 'kona_geni.cat' 'kona_geni.cat' 'TIML0001' 'NativeBoardInitEnabled,NativeGpiEnabled,WindowsIommuEnabled,FirmwareHandoffVerified,SourceClockHz,ReadOnlyHardwareProbeEnabled,NativeGpioI2cEnabled'
    New-TestPackage (Join-Path $root 'touch') 'vhidmini' 'sw42902.cat' 'sw42902.cat' 'LGSW4290' ''
    New-TestTrial (Join-Path $root 'trial')
    $installed = Join-Path $root 'installed'
    $null = New-Item -ItemType Directory -Path $installed -Force
    [IO.File]::WriteAllText((Join-Path $installed 'oem0.inf'),"[Manufacturer]`r`n%P%=D,ACPI\KONA1001`r`n")
    [IO.File]::WriteAllText((Join-Path $installed 'oem7.inf'),"[Manufacturer]`r`n%P%=D,ACPI\OTHER1234`r`n")
    $bundle = Join-Path $root 'bundle'
    & $builder -GpioPackage (Join-Path $root 'gpio') -HostPackage (Join-Path $root 'host') `
        -TouchPackage (Join-Path $root 'touch') -Trial (Join-Path $root 'trial') -Output $bundle `
        -InstalledInfFolder $installed -Receipt (Join-Path $root 'receipt.json')
    $manifest = Get-TouchGpioManifest $bundle
    if (@($manifest.packages).Count -ne 3 -or @($manifest.files).Count -ne 12) {throw 'Bundle manifest is incomplete'}
    $gpio = @($manifest.packages | Where-Object {$_.name -ceq 'GPIO'})[0]
    if (@($gpio.replaces_inf_sha256).Count -ne 1 -or
        $gpio.replaces_inf_sha256[0] -ne (Get-FileHash -LiteralPath (Join-Path $installed 'oem0.inf') -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Installed INF replacement hash was not recorded'
    }
    $touch = @($manifest.packages | Where-Object {$_.name -ceq 'Touch'})[0]
    if (@($touch.replaces_inf_sha256).Count -ne 0) {throw 'Unrelated installed INF was recorded as replaced'}
    # The bundle must be refused when the phone could not replace it later.
    Expect-Rejection 'existing bundle directory' {
        & $builder -GpioPackage (Join-Path $root 'gpio') -HostPackage (Join-Path $root 'host') `
            -TouchPackage (Join-Path $root 'touch') -Trial (Join-Path $root 'trial') -Output $bundle
    } 'existing bundle directory'
    $wrong = Join-Path $root 'wrong-id'
    New-TestPackage $wrong 'GPIO' 'GPIO.cat' 'GPIO.cat' 'KONA9999' ''
    Expect-Rejection 'wrong hardware ID' {
        & $builder -GpioPackage $wrong -HostPackage (Join-Path $root 'host') -TouchPackage (Join-Path $root 'touch') `
            -Trial (Join-Path $root 'trial') -Output (Join-Path $root 'bundle-wrong-id')
    } 'Wrong hardware ID'
    $catalog = Join-Path $root 'wrong-catalog'
    New-TestPackage $catalog 'GPIO' 'GPIO.cat' 'other.cat' 'KONA1001' ''
    Expect-Rejection 'catalog mismatch' {
        & $builder -GpioPackage $catalog -HostPackage (Join-Path $root 'host') -TouchPackage (Join-Path $root 'touch') `
            -Trial (Join-Path $root 'trial') -Output (Join-Path $root 'bundle-wrong-catalog')
    } 'Catalog mismatch'
    $trial = Join-Path $root 'trial-broken'
    New-TestTrial $trial
    # Keep the PE header valid so only the recorded hash can reject this trial.
    $tampered = [IO.File]::ReadAllBytes((Join-Path $trial 'TouchGpioOnce.efi'))
    $tampered[300] = $tampered[300] -bxor 0xff
    [IO.File]::WriteAllBytes((Join-Path $trial 'TouchGpioOnce.efi'),$tampered)
    Expect-Rejection 'trial metadata mismatch' {
        & $builder -GpioPackage (Join-Path $root 'gpio') -HostPackage (Join-Path $root 'host') -TouchPackage (Join-Path $root 'touch') `
            -Trial $trial -Output (Join-Path $root 'bundle-broken-trial')
    } 'does not match its metadata'
    # A failed build must not leave a half-written bundle behind.
    if (Test-Path -LiteralPath (Join-Path $root 'bundle-wrong-id')) {throw 'Failed build left a bundle directory'}
    if (!(Test-Path -LiteralPath $bundle)) {throw 'Refused build removed the existing bundle'}
    'PASS: the GPIO trial bundle builder assembles a verifiable package and rejects wrong IDs, catalogs and trial metadata.'
} finally {
    if (Test-Path -LiteralPath $root) {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
