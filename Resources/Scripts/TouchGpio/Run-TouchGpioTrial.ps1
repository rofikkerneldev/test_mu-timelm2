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
$script:activeWatches = New-Object 'System.Collections.Generic.List[object]'
# A monotonic budget bounds the whole trial. The phone clock is corrected
# before this task starts and must not move while it runs, and a stopwatch
# keeps the bound even if the clock is corrected again by something else.
$budget = [Diagnostics.Stopwatch]::StartNew()
$budgetLimit = [TimeSpan]::FromMinutes(25)
function Assert-Budget([string]$Phase) {
    if ($budget.Elapsed -gt $budgetLimit) {throw "Trial budget of $($budgetLimit.TotalMinutes) minutes exceeded in phase $Phase"}
}
function Wait-Seconds([int]$Seconds, [string]$Phase) {
    $remaining = $Seconds
    while ($remaining -gt 0) {
        Assert-Budget $Phase
        $slice = [Math]::Min(5, $remaining)
        Start-Sleep -Seconds $slice
        $remaining -= $slice
    }
}
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
    # 259 is ERROR_NO_MORE_ITEMS. PnPUtil returns it when the package was
    # staged but no device had to be updated, which is the normal answer when
    # the driver is already the selected one for that device. Treating it as a
    # failure aborted a real attempt before any hardware step, even though the
    # install itself had succeeded. The selected INF of the exact device is
    # verified separately, so the package identity is still proven.
    if ($code -eq 0 -or $code -eq 259) {return}
    throw "PnPUtil $Label returned $code"
}
function Start-NodeWatch([string]$Label, [int]$Seconds) {
    # The ACPI child of the I2C host may exist for a moment before Windows
    # removes it again, so the node list is sampled continuously while the
    # provider is restarted instead of being read once afterwards.
    $out = Join-Path $logs ('watch-'+$Label+'.jsonl')
    $watch = [ordered]@{label=$Label;output=$out;seconds=$Seconds;process_id=$null;error=$null;
        started=[DateTime]::UtcNow.ToString('o')}
    try {
        $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Watch-DeviceNodes.ps1'),
                '-Output',$out,'-Seconds',$Seconds) -WindowStyle Hidden -PassThru
        $watch.process_id = $process.Id
    } catch {
        $watch.error = $_.Exception.Message
    }
    $script:activeWatches.Add($watch)
    return $watch
}
function Stop-NodeWatch($Watch) {
    if ($null -eq $Watch -or !$Watch.process_id) {return}
    try {Stop-Process -Id $Watch.process_id -Force -ErrorAction SilentlyContinue} catch {}
}
function Copy-SetupApiLog([string]$Label) {
    # The SetupAPI log is a rolling file. A snapshot right after each install
    # keeps the decision of that install, which the rolling log can lose.
    try {
        $source = Join-Path $env:SystemRoot 'INF\setupapi.dev.log'
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $logs ('setupapi-'+$Label+'.log')) -Force
        }
    } catch {}
}
function Start-LiveTrace {
    # A live trace of the kernel PnP and ACPI providers records the device node
    # decisions as they happen. It is a diagnostic only: the session is stopped
    # again before the phone shuts down, and a failure to start it never fails
    # the trial.
    $state = [ordered]@{started=$false;session='TimelmTouchTrace';output=(Join-Path $logs 'live-pnp-trace.etl');
        providers=(Join-Path $logs 'live-trace-providers.txt');error=$null;utc=[DateTime]::UtcNow.ToString('o')}
    try {
        # logman takes only one provider per -p option, so the provider list
        # is written to a file and passed with -pf.
        Set-Content -LiteralPath $state.providers -Encoding ASCII -Value @(
            'Microsoft-Windows-Kernel-PnP 0xFFFFFFFF 0xFF',
            'Microsoft-Windows-Kernel-Acpi 0xFFFFFFFF 0xFF',
            'Microsoft-Windows-DriverFrameworks-UserMode 0xFFFFFFFF 0xFF')
        $output = & logman.exe create trace $state.session -pf $state.providers -ets -o $state.output -mode circular -max 64 2>&1
        $state.exit_code = $LASTEXITCODE
        $state.output_text = ($output | Out-String)
        $state.started = ($LASTEXITCODE -eq 0)
    } catch {
        $state.error = $_.Exception.Message
    }
    Save-Json 'live-trace-start.json' $state
    return $state
}
function Stop-LiveTrace($Trace) {
    if ($null -eq $Trace -or !$Trace.started) {return}
    try {
        $output = & logman.exe stop $Trace.session -ets 2>&1
        Save-Json 'live-trace-stop.json' @{session=$Trace.session;exit_code=$LASTEXITCODE;
            output=($output | Out-String);utc=[DateTime]::UtcNow.ToString('o')}
    } catch {
        Save-Json 'live-trace-stop.json' @{session=$Trace.session;error=$_.Exception.Message;utc=[DateTime]::UtcNow.ToString('o')}
    }
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
function Get-SelectedInf([string]$PackageName, [string]$DeviceId) {
    # PnPUtil can successfully stage a package while retaining an older driver.
    # Follow the exact device's selected class key, not a matching INF search.
    # The result also tells a later phase whether this bundle's own driver is
    # already the selected one, which is how leftovers of an interrupted
    # attempt are told apart from a foreign state.
    $packages = @($manifest.packages | Where-Object {$_.name -ceq $PackageName})
    if ($packages.Count -ne 1) {throw 'Selected INF check has no unique package'}
    $package = $packages[0]
    $relative = 'Drivers/'+$PackageName+'/'+$package.inf
    $files = @($manifest.files | Where-Object {$_.path -ceq $relative})
    if ($files.Count -ne 1) {throw 'Selected INF check has no unique hash'}
    $expected = $files[0].sha256
    $driver = Get-ItemPropertyValue -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\'+$DeviceId) -Name 'Driver'
    if ($driver -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\\[0-9a-fA-F]{4}$') {
        return [ordered]@{device=$DeviceId;inf=$null;sha256=$null;expected_sha256=$expected;matches=$false;class_key=$null}
    }
    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\'+$driver
    $infName = Get-ItemPropertyValue -LiteralPath $classKey -Name 'InfPath'
    if ($infName -notmatch '^oem[0-9]+\.inf$') {
        return [ordered]@{device=$DeviceId;inf=$null;sha256=$null;expected_sha256=$expected;matches=$false;class_key=$driver}
    }
    $actual = (Get-FileHash -LiteralPath (Join-Path $env:SystemRoot ('INF\'+$infName))).Hash
    return [ordered]@{device=$DeviceId;inf=$infName;sha256=$actual;expected_sha256=$expected;
        matches=($actual -eq $expected);class_key=$driver}
}
function Assert-SelectedInf([string]$PackageName, [string]$DeviceId) {
    $selection = Get-SelectedInf $PackageName $DeviceId
    if (!$selection.matches) {throw "PnP retained an unexpected $PackageName driver; hardware activation refused"}
    Save-Json ('selected-'+$PackageName+'-inf.json') @{device=$DeviceId;class_key=$selection.class_key;inf=$selection.inf;
        sha256=$selection.sha256;expected_sha256=$selection.expected_sha256;matches=$true;utc=[DateTime]::UtcNow.ToString('o')}
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
    Wait-Seconds 20 'awake-hold'
    $manifest = Get-TouchGpioManifest $PSScriptRoot
    # The clock is never changed under this task. A clock jump while a task
    # with an execution time limit is running makes Task Scheduler compute the
    # task runtime from the new time and hard terminate the action, which
    # ended a previous attempt before any hardware step and left neither a
    # completion nor an error receipt behind. The launcher sets the clock
    # before the task exists, so a wrong clock here is refused before
    # anything on the phone is touched.
    $hostUtc = [DateTime]::Parse((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'host-utc.txt') -Raw).Trim()).ToUniversalTime()
    $certificates = @()
    foreach ($p in $manifest.packages) {
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2((Join-Path $PSScriptRoot ('Drivers/'+$p.name+'/'+$p.certificate)))
        if ($hostUtc -lt $cert.NotBefore.ToUniversalTime() -or $hostUtc -gt $cert.NotAfter.ToUniversalTime()) {throw 'PC reference time outside package certificate validity'}
        $certificates += $cert
    }
    $clockBefore = [DateTime]::UtcNow
    foreach ($cert in $certificates) {
        if ($clockBefore -lt $cert.NotBefore.ToUniversalTime() -or $clockBefore -gt $cert.NotAfter.ToUniversalTime()) {
            throw 'Phone clock outside certificate validity; the launcher must set the clock before the task starts'
        }
    }
    Save-Json 'clock.json' @{before_utc=$clockBefore.ToString('o');after_utc=[DateTime]::UtcNow.ToString('o');
        host_utc=$hostUtc.ToString('o');adjusted_by_task=$false}
    # An interrupted attempt can leave this bundle's own driver selected and
    # its gates enabled. Read the selection first: only a driver from this
    # bundle may explain an enabled gate, and only that case may be restored.
    # The restore happens before the baseline is collected, so the evidence is
    # taken with the hardware path disabled.
    $gpioSelection = Get-SelectedInf 'GPIO' $gpioId
    $hostSelection = Get-SelectedInf 'Host' $hostId
    $previousGates = @{}
    $restoredGates = @()
    foreach ($entry in @(@{path=$hostKey;names=($gates+@('NativeGpioI2cEnabled'));selection=$hostSelection},
                         @{path=$gpioKey;names=@('TouchBusGpioEnabled');selection=$gpioSelection})) {
        $values = @{}
        foreach ($name in $entry.names) {
            $value = Get-Gate $entry.path $name
            $values[$name] = $value
            if ($null -ne $value -and $value -ne 0) {
                # A gate that was enabled by anything but this bundle's own
                # driver is refused, never reset.
                if (!$entry.selection.matches) {throw "Pre-existing hardware gate enabled: $name"}
                Set-Gate $entry.path $name 0
                $restoredGates += $name
            }
        }
        $previousGates[$entry.path] = $values
    }
    Save-Json 'gates-before.json' $previousGates
    if ($restoredGates.Count) {
        Save-Json 'gates-restored.json' @{restored=$restoredGates;utc=[DateTime]::UtcNow.ToString('o')}
    }
    $before = Collect-Phase 'before'
    Assert-Budget 'baseline'
    $tables = Get-Content -LiteralPath (Join-Path $before 'acpi-table-list.json') -Raw | ConvertFrom-Json
    if (@($tables.tables | Where-Object {$_.signature -eq 'IORT'}).Count) {throw 'Unexpected IORT; GPIO trial requires no SMMU owner change'}
    $ssdt = @(Get-ChildItem -LiteralPath $before -Filter '*SSDT*.dat' -File | Where-Object {(Get-FileHash -LiteralPath $_.FullName).Hash -eq $manifest.ssdt_sha256})
    if ($ssdt.Count -ne 1) {throw 'Expected GPIO-only trial SSDT missing'}
    $gpio = Get-TouchGpioDevice $gpioId
    $hostDevice = Get-TouchGpioDevice $hostId
    # The driver selection and the gate restore were already read and applied
    # before the baseline was collected.
    $hostErrorAllowed = @(10,28,31)
    if ($hostSelection.matches) {$hostErrorAllowed += 0}
    if ($gpio.ConfigManagerErrorCode -ne 0 -or $gpio.Service -ine 'GPIO' -or
        $hostDevice.ConfigManagerErrorCode -notin $hostErrorAllowed -or
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
    Assert-Budget 'install-gpio'
    # The live trace and the node sampler run over the whole installation, so
    # the device node decisions of this attempt are recorded while they happen.
    $liveTrace = Start-LiveTrace
    # GPIO gate must be visible when the replacement provider creates its v3 interface.
    Pnp 'install-GPIO' @('/add-driver',(Join-Path $PSScriptRoot 'Drivers\GPIO\GPIO.inf'),'/install')
    Assert-SelectedInf 'GPIO' $gpioId
    Copy-SetupApiLog 'after-gpio-install'
    Set-Gate $gpioKey 'TouchBusGpioEnabled' 1
    $watchGpio = Start-NodeWatch 'gpio' 30
    Pnp 'restart-GPIO' @('/restart-device',$gpioId)
    Wait-Seconds 5 'gpio-restart'
    $gpio = Get-TouchGpioDevice $gpioId
    Stop-NodeWatch $watchGpio
    Copy-SetupApiLog 'after-gpio-restart'
    if ($gpio.ConfigManagerErrorCode -ne 0 -or $gpio.Service -ine 'GPIO') {throw 'GPIO provider failed after upgrade/restart'}
    # Every hardware phase publishes a receipt. The Device Manager helper in
    # the desktop session watches them and refreshes the console tree, so the
    # loaded drivers are visible while the trial continues.
    Save-Json 'phase-gpio-started.json' @{phase='gpio-started';device=$gpioId;service=$gpio.Service;
        code=$gpio.ConfigManagerErrorCode;utc=[DateTime]::UtcNow.ToString('o')}
    Assert-Budget 'install-host'
    Pnp 'install-Host' @('/add-driver',(Join-Path $PSScriptRoot 'Drivers\Host\kona_geni.inf'),'/install')
    Assert-SelectedInf 'Host' $hostId
    Copy-SetupApiLog 'after-host-install'
    foreach ($gate in $gates) {Set-Gate $hostKey $gate 0}
    Set-Gate $hostKey 'NativeGpioI2cEnabled' 1
    Save-Json 'gates-enabled.json' @{GPIO=(Get-ItemProperty -LiteralPath $gpioKey);Host=(Get-ItemProperty -LiteralPath $hostKey);dma_enabled=$false}
    # The host start is the moment the ACPI child of the bus has to appear.
    # The sampler runs across the restart, so a child node that exists only
    # briefly is still recorded.
    $watchHost = Start-NodeWatch 'host' 60
    Pnp 'restart-Host' @('/restart-device',$hostId)
    $testWindow = $true
    Wait-Seconds 5 'host-restart'
    $hostDevice = Get-TouchGpioDevice $hostId
    Stop-NodeWatch $watchHost
    Copy-SetupApiLog 'after-host-restart'
    if ($hostDevice.ConfigManagerErrorCode -ne 0 -or $hostDevice.Service -ine 'kona_geni') {throw 'GPIO I2C host did not start; inspect product/ACK diagnostics'}
    # The record of the driver itself is the proof that the bitbang path was
    # entered: the stage 1 is the first action of the prepare.  Without that
    # value the host stayed in the legacy path, whatever the gates say.
    $hostParameters = Get-ItemProperty -LiteralPath $hostKey -ErrorAction SilentlyContinue
    $hostNames = @()
    if ($hostParameters) { $hostNames = @($hostParameters.PSObject.Properties.Name) }
    $bitbangStage = 0
    if ($hostNames -contains 'TimelmBitbangStage') { $bitbangStage = [int]$hostParameters.TimelmBitbangStage }
    $hostStatus = -1
    if ($hostNames -contains 'TimelmHostStatus') { $hostStatus = [int]$hostParameters.TimelmHostStatus }
    $bitbangStatus = -1
    if ($hostNames -contains 'TimelmBitbangStatus') { $bitbangStatus = [int]$hostParameters.TimelmBitbangStatus }
    Save-Json 'host-parameters.json' $hostParameters
    Save-Json 'host-bitbang.json' @{bitbang_stage=$bitbangStage;host_status=$hostStatus;
        bitbang_status=$bitbangStatus;utc=[DateTime]::UtcNow.ToString('o')}
    if ($bitbangStage -lt 1) {
        throw 'the host did not enter the bitbang path, the driver wrote no TimelmBitbangStage'
    }
    Save-Json 'phase-host-started.json' @{phase='host-started';device=$hostId;service=$hostDevice.Service;
        code=$hostDevice.ConfigManagerErrorCode;utc=[DateTime]::UtcNow.ToString('o')}
    Assert-Budget 'install-touch'
    $watchTouch = Start-NodeWatch 'touch' 40
    Pnp 'install-Touch' @('/add-driver',(Join-Path $PSScriptRoot 'Drivers\Touch\vhidmini.inf'),'/install')
    Copy-SetupApiLog 'after-touch-install'
    $touchDevices = @(Get-CimInstance Win32_PnPEntity | Where-Object {$_.PNPDeviceID -like 'ACPI\LGSW4290\*'})
    Stop-NodeWatch $watchTouch
    Copy-SetupApiLog 'after-touch-enumeration'
    if ($touchDevices.Count -ne 1) {throw 'Expected exactly one SW42902 device after client installation'}
    Assert-SelectedInf 'Touch' $touchDevices[0].PNPDeviceID
    Save-Json 'touch-window.json' @{utc=[DateTime]::UtcNow.ToString('o');seconds=120;instruction='Try taps and swipes. Automatic normal shutdown follows log collection.'}
    Save-Json 'phase-test-window.json' @{phase='test-window';device=$touchDevices[0].PNPDeviceID;seconds=120;
        instruction='Try taps and swipes; Device Manager is open expanded on the desktop.';
        utc=[DateTime]::UtcNow.ToString('o')}
} catch {
    $trialError = $_.Exception.Message
    Save-Json 'trial-error.json' @{error=$trialError;need_next_boot=$needNextBoot;utc=[DateTime]::UtcNow.ToString('o')}
}
if ($testWindow -and !$needNextBoot) {
    Wait-Seconds 120 'test-window'
}
try {
    # The live trace is closed before the evidence is collected, so the trace
    # file is complete in the log tree. Every sampler is stopped as well.
    Stop-LiveTrace $liveTrace
} catch {}
foreach ($watch in @($script:activeWatches.ToArray())) {Stop-NodeWatch $watch}
try {
    $after = Collect-Phase 'after'
    Save-Json 'complete.json' @{after=$after;error=$trialError;need_next_boot=$needNextBoot;normal_shutdown=$true;utc=[DateTime]::UtcNow.ToString('o')}
} catch {Save-Json 'collection-failed.json' @{error=$_.Exception.Message;trial_error=$trialError;utc=[DateTime]::UtcNow.ToString('o')}}
finally {if ($awake) {[TouchGpioAwake]::Release();$awake = $false}
    foreach ($watch in @($script:activeWatches.ToArray())) {Stop-NodeWatch $watch}}
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
