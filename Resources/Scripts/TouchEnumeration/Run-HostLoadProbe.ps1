# One attempt on the ARM64 phone. Default-off host package only; no GPIO/touch install.
$ErrorActionPreference='Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60') {throw 'Wrong machine'}
$marker=Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker'
if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') {throw 'Wrong installation'}
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') {throw 'Desktop required'}
$setup=Get-ItemProperty 'HKLM:\SYSTEM\Setup'
if ($setup.SystemSetupInProgress -ne 0 -or $setup.OOBEInProgress -ne 0) {throw 'Setup incomplete'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Elevated phone Administrator required'}
$logs=Join-Path $env:SystemDrive 'TimelmLogs\TouchHostLoadProbe'
$null=New-Item -ItemType Directory -Path $logs -Force
if (Test-Path -LiteralPath (Join-Path $logs 'attempt.json')) {return}
[ordered]@{utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $logs 'attempt.json')
$startup=Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\Timelm-touch-host-load.cmd'
if ((Test-Path -LiteralPath $startup) -and
    (Get-FileHash -LiteralPath $startup).Hash -eq (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Timelm-touch-host-load.cmd')).Hash) {
    Remove-Item -LiteralPath $startup
}
. (Join-Path $PSScriptRoot 'Invoke-ProbeProcess.ps1')
function Collect-Phase([string]$Phase) {
    $dest=Join-Path $logs $Phase
    $null=New-Item -ItemType Directory -Path $dest
    $code=Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Collect-TimelmDiagnostics.ps1'),'-SkipEsp','-OutputRoot',$dest) `
        -StdoutPath (Join-Path $dest 'stdout.txt') -StderrPath (Join-Path $dest 'stderr.txt')
    if ($code -ne 0) {throw "Collector $Phase exited $code"}
    $receipts=@(Get-ChildItem -LiteralPath $dest -Filter 'collection-status.json' -File -Recurse)
    if ($receipts.Count -ne 1) {throw 'Missing collector receipt'}
    return $receipts[0].DirectoryName
}
$installError=$null
try {
    Start-Sleep -Seconds 30
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'HostLoadPackage.json') -Raw | ConvertFrom-Json
    foreach ($file in $manifest.files) {
        if ($file.name -notin @('kona_geni.inf','kona_geni.sys','kona_geni.cat','kona_geni.cer')) {throw 'Unexpected package file'}
        $path=Join-Path $PSScriptRoot ('HostPackage\'+$file.name)
        if ((Get-Item -LiteralPath $path).Length -ne $file.size -or (Get-FileHash -LiteralPath $path).Hash -ne $file.sha256) {throw 'Package hash mismatch'}
    }
    $before=Collect-Phase 'before'
    $tables=Get-Content -LiteralPath (Join-Path $before 'acpi-table-list.json') -Raw | ConvertFrom-Json
    if (@($tables.tables | Where-Object {$_.signature -eq 'IORT'}).Count -ne 0) {throw 'Unexpected IORT'}
    if ((Get-FileHash -LiteralPath (Join-Path $before 'SSDT.dat')).Hash -ne $manifest.ssdt_sha256) {throw 'Expected one-boot SSDT missing'}
    $entities=Get-Content -LiteralPath (Join-Path $before 'pnp-entities.json') -Raw | ConvertFrom-Json
    $hostDevice=@($entities | Where-Object {$_.PNPDeviceID -eq 'ACPI\TIML0001\E'})
    if ($hostDevice.Count -ne 1 -or $hostDevice[0].ConfigManagerErrorCode -ne 28 -or $hostDevice[0].Service) {throw 'Host must be present without a driver'}
    $existing=@(Get-ChildItem "$env:SystemRoot\INF" -Filter '*.inf' -File | Select-String -Pattern 'TIML0001|LGSW4290')
    if ($existing.Count) {throw 'Unexpected installed host/touch INF'}
    $deviceKey='HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\TIML0001\e\Device Parameters'
    if (Test-Path -LiteralPath $deviceKey) {
        $props=Get-ItemProperty -LiteralPath $deviceKey
        foreach ($name in @('NativeBoardInitEnabled','NativeGpiEnabled','WindowsIommuEnabled','FirmwareHandoffVerified','SourceClockHz')) {
            if ($props.$name -and $props.$name -ne 0) {throw "Previously enabled hardware gate: $name"}
        }
    }
    $certPath=Join-Path $PSScriptRoot 'HostPackage\kona_geni.cer'
    $cert=New-Object Security.Cryptography.X509Certificates.X509Certificate2($certPath)
    if ($cert.Thumbprint -ne $manifest.certificate_thumbprint) {throw 'Unexpected certificate'}
    $clockBefore=[DateTime]::UtcNow
    $hostUtc=[DateTime]::Parse((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'host-utc.txt') -Raw).Trim()).ToUniversalTime()
    if ($hostUtc -lt $cert.NotBefore.ToUniversalTime() -or $hostUtc -gt $cert.NotAfter.ToUniversalTime()) {throw 'PC time outside certificate validity'}
    if ([DateTime]::UtcNow -lt $cert.NotBefore.ToUniversalTime()) {
        Set-Date -Date $hostUtc.ToLocalTime() | Out-Null
    }
    if ([DateTime]::UtcNow -lt $cert.NotBefore.ToUniversalTime() -or [DateTime]::UtcNow -gt $cert.NotAfter.ToUniversalTime()) {throw 'Phone clock outside certificate validity'}
    [ordered]@{before_utc=$clockBefore.ToString('o');after_utc=[DateTime]::UtcNow.ToString('o');pc_reference_utc=$hostUtc.ToString('o')} |
        ConvertTo-Json | Set-Content (Join-Path $logs 'clock.json')
    $trust=@()
    foreach ($name in @('Root','TrustedPublisher')) {
        $store=New-Object Security.Cryptography.X509Certificates.X509Store($name,'LocalMachine')
        try {
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $present=@($store.Certificates | Where-Object {$_.Thumbprint -eq $cert.Thumbprint}).Count -gt 0
            if (!$present) {$store.Add($cert)}
            $trust += [ordered]@{store=$name;thumbprint=$cert.Thumbprint;already_present=$present}
        } finally {$store.Close()}
    }
    $trust | ConvertTo-Json | Set-Content (Join-Path $logs 'certificate-stores.json')
    $code=Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\pnputil.exe" `
        -Arguments @('/add-driver',(Join-Path $PSScriptRoot 'HostPackage\kona_geni.inf'),'/install') `
        -StdoutPath (Join-Path $logs 'install-output.txt') -StderrPath (Join-Path $logs 'install-error.txt') -TimeoutMs 180000
    [ordered]@{exit_code=$code;automatic_reboot_requested=$false;gates_enabled=$false} |
        ConvertTo-Json | Set-Content (Join-Path $logs 'install-result.json')
    if ($code -notin @(0,3010)) {throw "PnPUtil install returned $code"}
    Start-Sleep -Seconds 15
} catch {
    $installError=$_.Exception.Message
    [ordered]@{phase='install-failed-or-blocked';error=$installError;utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content (Join-Path $logs 'failed.json')
}
try {
    $after=Collect-Phase 'after'
    [ordered]@{phase='collected';install_error=$installError;after=$after;utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content (Join-Path $logs 'complete.json')
} catch {
    [ordered]@{error=$_.Exception.Message;utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content (Join-Path $logs 'collection-failed.json')
}
& "$env:SystemRoot\System32\shutdown.exe" /s /t 30 /c 'Timelm host load trial complete. Logs saved for offline inspection.'
if ($LASTEXITCODE -ne 0) {throw 'Shutdown request failed'}
