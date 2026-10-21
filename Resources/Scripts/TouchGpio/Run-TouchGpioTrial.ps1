# One attempt on the identified ARM64 V60 desktop. Never run this on the PC.
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60') {throw 'Wrong machine'}
$marker = Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker'
if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') {throw 'Wrong installation'}
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') {throw 'Desktop required'}
$setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
if ($setup.SystemSetupInProgress -ne 0 -or $setup.OOBEInProgress -ne 0) {throw 'Setup incomplete'}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value -ne 'S-1-5-18') {throw 'Phone SYSTEM task identity required'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
. (Join-Path $PSScriptRoot 'Invoke-ProbeProcess.ps1')
$logs = Join-Path $env:SystemDrive 'TimelmLogs\TouchGpioTrial'
$null = New-Item -ItemType Directory -Path $logs -Force
$attempt = Join-Path $logs 'attempt.json'
# Atomic create prevents two concurrent startup launches from both installing.
try {$stream = [IO.File]::Open($attempt,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}
catch {if (Test-Path -LiteralPath $attempt) {return}; throw}
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(([ordered]@{utc=[DateTime]::UtcNow.ToString('o');sid=$identity.User.Value} | ConvertTo-Json))
    $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true)
} finally {$stream.Dispose()}
$startup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\Timelm-touch-gpio.cmd'
if ((Test-Path -LiteralPath $startup) -and
    (Get-FileHash -LiteralPath $startup).Hash -eq (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Timelm-touch-gpio.cmd')).Hash) {
    Copy-Item -LiteralPath $startup -Destination (Join-Path $logs 'startup-disarmed.cmd')
    Remove-Item -LiteralPath $startup
}
$hostId = 'ACPI\TIML0001\E'; $gpioId = 'ACPI\KONA1001\0'
$hostKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\'+$hostId+'\Device Parameters'
$gpioKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\'+$gpioId+'\Device Parameters'
$gates = @('NativeBoardInitEnabled','NativeGpiEnabled','WindowsIommuEnabled','FirmwareHandoffVerified','SourceClockHz','ReadOnlyHardwareProbeEnabled')
$needNextBoot = $false; $trialError = $null; $testWindow = $false; $awake = $false
$operations = New-Object 'System.Collections.Generic.List[object]'
function Save-Json([string]$Name, $Value) {
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $logs $Name)
}
function Collect-Phase([string]$Phase) {
    $dest = Join-Path $logs $Phase
    $null = New-Item -ItemType Directory -Path $dest
    $code = Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Collect-TimelmDiagnostics.ps1'),'-SkipEsp','-OutputRoot',$dest) `
        -StdoutPath (Join-Path $dest 'stdout.txt') -StderrPath (Join-Path $dest 'stderr.txt') -TimeoutMs 180000
    if ($code -ne 0) {throw "Collector $Phase returned $code"}
    $receipts = @(Get-ChildItem -LiteralPath $dest -Filter 'collection-status.json' -File -Recurse)
    if ($receipts.Count -ne 1) {throw "Collector receipt missing for $Phase"}
    return $receipts[0].DirectoryName
}
function Pnp([string]$Label, [string[]]$PnpArguments) {
    $code = Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\pnputil.exe" -Arguments $PnpArguments `
        -StdoutPath (Join-Path $logs ($Label+'-stdout.txt')) -StderrPath (Join-Path $logs ($Label+'-stderr.txt')) -TimeoutMs 180000
    $operations.Add([ordered]@{operation=$Label;arguments=$PnpArguments;exit_code=$code;utc=[DateTime]::UtcNow.ToString('o')})
    Save-Json 'operations.json' @($operations.ToArray())
    if ($code -eq 3010) {$script:needNextBoot = $true; throw 'Driver update requires a second boot; collecting before normal shutdown'}
    if ($code -ne 0) {throw "PnPUtil $Label returned $code"}
}
function Get-Gate([string]$Path, [string]$Name) {
    # Windows PowerShell 5.1 throws from Get-ItemPropertyValue when the
    # property does not exist, even with -ErrorAction SilentlyContinue. A gate
    # that is not written is not enabled, so read the key once and look the
    # single property up instead of asking for a value that may be absent.
    if (!(Test-Path -LiteralPath $Path)) {return $null}
    $key = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) {return $null}
    $property = $key.PSObject.Properties[$Name]
    if ($null -eq $property) {return $null}
    return $property.Value
}
function Set-Gate([string]$Path, [string]$Name, [int]$Value) {
    # Registry New-Item -Force replaces an existing key. Keep the provider's
    # other Device Parameters and gates when setting one explicit DWORD.
    if (!(Test-Path -LiteralPath $Path)) {$null = New-Item -Path $Path}
    $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force
    if ((Get-ItemPropertyValue -LiteralPath $Path -Name $Name) -ne $Value) {throw "Gate readback failed: $Name"}
}
function Assert-SelectedInf([string]$PackageName, [string]$DeviceId) {
    # PnPUtil can successfully stage a package while retaining an older driver.
    # Follow the exact device's selected class key, not a matching INF search.
    $packages = @($manifest.packages | Where-Object {$_.name -ceq $PackageName})
    if ($packages.Count -ne 1) {throw 'Selected INF check has no unique package'}
    $package = $packages[0]
    $relative = 'Drivers/'+$PackageName+'/'+$package.inf
    $files = @($manifest.files | Where-Object {$_.path -ceq $relative})
    if ($files.Count -ne 1) {throw 'Selected INF check has no unique hash'}
    $driver = Get-ItemPropertyValue -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\'+$DeviceId) -Name 'Driver'
    if ($driver -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\\[0-9a-fA-F]{4}$') {throw "Unexpected selected class key: $PackageName"}
    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\'+$driver
    $infName = Get-ItemPropertyValue -LiteralPath $classKey -Name 'InfPath'
    if ($infName -notmatch '^oem[0-9]+\.inf$') {throw "Unexpected selected INF path: $PackageName"}
    $actual = (Get-FileHash -LiteralPath (Join-Path $env:SystemRoot ('INF\'+$infName))).Hash
    $expected = $files[0].sha256
    Save-Json ('selected-'+$PackageName+'-inf.json') @{device=$DeviceId;class_key=$driver;inf=$infName;
        sha256=$actual;expected_sha256=$expected;matches=($actual -eq $expected);utc=[DateTime]::UtcNow.ToString('o')}
    if ($actual -ne $expected) {throw "PnP retained an unexpected $PackageName driver; hardware activation refused"}
}
try {
    # Hold the system and display throughout collection, installation and the
    # test window. This initial driver deliberately refuses D0 resume.
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class TouchGpioAwake {
  [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
  public static bool Hold() { return SetThreadExecutionState(0x80000003u) != 0; }
  public static void Release() { SetThreadExecutionState(0x80000000u); }
}
'@
    $awake = [TouchGpioAwake]::Hold()
    if (!$awake) {throw 'Temporary display/system awake request failed; hardware activation refused'}
    Start-Sleep -Seconds 20
    $manifest = Get-TouchGpioManifest $PSScriptRoot
    $before = Collect-Phase 'before'
    $tables = Get-Content -LiteralPath (Join-Path $before 'acpi-table-list.json') -Raw | ConvertFrom-Json
    if (@($tables.tables | Where-Object {$_.signature -eq 'IORT'}).Count) {throw 'Unexpected IORT; GPIO trial requires no SMMU owner change'}
    $ssdt = @(Get-ChildItem -LiteralPath $before -Filter '*SSDT*.dat' -File | Where-Object {(Get-FileHash -LiteralPath $_.FullName).Hash -eq $manifest.ssdt_sha256})
    if ($ssdt.Count -ne 1) {throw 'Expected GPIO-only trial SSDT missing'}
    $gpio = Get-TouchGpioDevice $gpioId
    $hostDevice = Get-TouchGpioDevice $hostId
    if ($gpio.ConfigManagerErrorCode -ne 0 -or $gpio.Service -ine 'GPIO' -or
        $hostDevice.ConfigManagerErrorCode -notin @(10,28,31) -or
        ($hostDevice.Service -and $hostDevice.Service -ine 'kona_geni')) {throw 'Unexpected initial GPIO/host state'}
    foreach ($p in $manifest.packages) {
        $pattern = switch ($p.name) {GPIO {'ACPI\\KONA1001'} Host {'ACPI\\TIML0001'} Touch {'ACPI\\LGSW4290'}}
        $newHash = @($manifest.files | Where-Object {$_.path -ceq ('Drivers/'+$p.name+'/'+$p.inf)})[0].sha256
        $allowed = @($p.replaces_inf_sha256) + @($newHash)
        $installed = @(Get-ChildItem -LiteralPath "$env:SystemRoot\INF" -Filter '*.inf' -File | Select-String -Pattern $pattern -List)
        foreach ($entry in $installed) {
            if ((Get-FileHash -LiteralPath $entry.Path).Hash -notin $allowed) {throw "Unexpected installed $($p.name) INF"}
        }
    }
    $previousGates = @{}
    foreach ($entry in @(@{path=$hostKey;names=($gates+@('NativeGpioI2cEnabled'))},@{path=$gpioKey;names=@('TouchBusGpioEnabled')})) {
        $values = @{}
        foreach ($name in $entry.names) {
            $value = Get-Gate $entry.path $name
            $values[$name] = $value
            if ($null -ne $value -and $value -ne 0) {throw "Pre-existing hardware gate enabled: $name"}
        }
        $previousGates[$entry.path] = $values
    }
    Save-Json 'gates-before.json' $previousGates
    $hostUtc = [DateTime]::Parse((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'host-utc.txt') -Raw).Trim()).ToUniversalTime()
    $certificates = @()
    foreach ($p in $manifest.packages) {
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2((Join-Path $PSScriptRoot ('Drivers/'+$p.name+'/'+$p.certificate)))
        if ($hostUtc -lt $cert.NotBefore.ToUniversalTime() -or $hostUtc -gt $cert.NotAfter.ToUniversalTime()) {throw 'PC reference time outside package certificate validity'}
        $certificates += $cert
    }
    $clockBefore = [DateTime]::UtcNow
    if (@($certificates | Where-Object {$clockBefore -lt $_.NotBefore.ToUniversalTime()}).Count) {Set-Date -Date $hostUtc.ToLocalTime() | Out-Null}
    foreach ($cert in $certificates) {
        if ([DateTime]::UtcNow -lt $cert.NotBefore.ToUniversalTime() -or [DateTime]::UtcNow -gt $cert.NotAfter.ToUniversalTime()) {throw 'Phone time outside certificate validity'}
        foreach ($storeName in @('Root','TrustedPublisher')) {
            $store = New-Object Security.Cryptography.X509Certificates.X509Store($storeName,'LocalMachine')
            try {
                $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                $present = @($store.Certificates | Where-Object {$_.Thumbprint -eq $cert.Thumbprint}).Count -gt 0
                if (!$present) {$store.Add($cert)}
                $operations.Add([ordered]@{operation='certificate';store=$storeName;thumbprint=$cert.Thumbprint;already_present=$present})
            } finally {$store.Close()}
        }
        $cert.Reset()
    }
    Save-Json 'clock.json' @{before_utc=$clockBefore.ToString('o');after_utc=[DateTime]::UtcNow.ToString('o');host_utc=$hostUtc.ToString('o')}
    # GPIO gate must be visible when the replacement provider creates its v3 interface.
    Pnp 'install-GPIO' @('/add-driver',(Join-Path $PSScriptRoot 'Drivers\GPIO\GPIO.inf'),'/install')
    Assert-SelectedInf 'GPIO' $gpioId
    Set-Gate $gpioKey 'TouchBusGpioEnabled' 1
    Pnp 'restart-GPIO' @('/restart-device',$gpioId)
    Start-Sleep -Seconds 5
    $gpio = Get-TouchGpioDevice $gpioId
    if ($gpio.ConfigManagerErrorCode -ne 0 -or $gpio.Service -ine 'GPIO') {throw 'GPIO provider failed after upgrade/restart'}
    Pnp 'install-Host' @('/add-driver',(Join-Path $PSScriptRoot 'Drivers\Host\kona_geni.inf'),'/install')
    Assert-SelectedInf 'Host' $hostId
    foreach ($gate in $gates) {Set-Gate $hostKey $gate 0}
    Set-Gate $hostKey 'NativeGpioI2cEnabled' 1
    Save-Json 'gates-enabled.json' @{GPIO=(Get-ItemProperty -LiteralPath $gpioKey);Host=(Get-ItemProperty -LiteralPath $hostKey);dma_enabled=$false}
    Pnp 'restart-Host' @('/restart-device',$hostId)
    $testWindow = $true
    Start-Sleep -Seconds 5
    $hostDevice = Get-TouchGpioDevice $hostId
    if ($hostDevice.ConfigManagerErrorCode -ne 0 -or $hostDevice.Service -ine 'kona_geni') {throw 'GPIO I2C host did not start; inspect product/ACK diagnostics'}
    Pnp 'install-Touch' @('/add-driver',(Join-Path $PSScriptRoot 'Drivers\Touch\vhidmini.inf'),'/install')
    $touchDevices = @(Get-CimInstance Win32_PnPEntity | Where-Object {$_.PNPDeviceID -like 'ACPI\LGSW4290\*'})
    if ($touchDevices.Count -ne 1) {throw 'Expected exactly one SW42902 device after client installation'}
    Assert-SelectedInf 'Touch' $touchDevices[0].PNPDeviceID
    Save-Json 'touch-window.json' @{utc=[DateTime]::UtcNow.ToString('o');seconds=120;instruction='Try taps and swipes. Automatic normal shutdown follows log collection.'}
} catch {
    $trialError = $_.Exception.Message
    Save-Json 'trial-error.json' @{error=$trialError;need_next_boot=$needNextBoot;utc=[DateTime]::UtcNow.ToString('o')}
}
if ($testWindow -and !$needNextBoot) {
    Start-Sleep -Seconds 120
}
try {
    $after = Collect-Phase 'after'
    Save-Json 'complete.json' @{after=$after;error=$trialError;need_next_boot=$needNextBoot;normal_shutdown=$true;utc=[DateTime]::UtcNow.ToString('o')}
} catch {Save-Json 'collection-failed.json' @{error=$_.Exception.Message;trial_error=$trialError;utc=[DateTime]::UtcNow.ToString('o')}}
finally {if ($awake) {[TouchGpioAwake]::Release();$awake = $false}}
Save-Json 'operations.json' @($operations.ToArray())
try {
    $task = Get-ScheduledTask -TaskName 'TimelmTouchGpioOnce' -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) {
        $expectedExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $expectedArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'Run-TouchGpioTrial.ps1')+'"'
        if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine $expectedExe -or
            $task.Actions[0].Arguments -cne $expectedArgs -or $task.Principal.UserId -notin @('SYSTEM','S-1-5-18')) {throw 'Refusing to remove an unrelated task'}
        Unregister-ScheduledTask -TaskName 'TimelmTouchGpioOnce' -TaskPath '\' -Confirm:$false
        Save-Json 'task-cleanup.json' @{removed=$true;utc=[DateTime]::UtcNow.ToString('o')}
    }
} catch {Save-Json 'task-cleanup-error.json' @{error=$_.Exception.Message}}
& "$env:SystemRoot\System32\shutdown.exe" /s /t 30 /c 'Timelm GPIO touch trial complete. Logs saved; reconnect Mu Mass Storage.'
if ($LASTEXITCODE -ne 0) {throw 'Normal shutdown request failed'}
