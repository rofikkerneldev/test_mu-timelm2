# One worker attempt on the identified ARM64 V60. The supervisor owns shutdown.
param([switch]$Supervised)
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60') {throw 'Wrong machine'}
$marker = Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker'
if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') {throw 'Wrong installation'}
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') {throw 'Desktop required'}
$setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup'
if ($setup.SystemSetupInProgress -ne 0 -or $setup.OOBEInProgress -ne 0) {throw 'Setup incomplete'}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value -ne 'S-1-5-18') {throw 'Phone SYSTEM task identity required'}
if (!$Supervised) {throw 'Run through Invoke-TouchGpioSupervised.ps1'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
. (Join-Path $PSScriptRoot 'Invoke-ProbeProcess.ps1')
$snapshotReader=Join-Path $PSScriptRoot 'Export-TouchGpioRegistryValues.ps1'
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
$script:attemptId = 0
$script:runnerId = [guid]::NewGuid().ToString('N')
$operations = New-Object 'System.Collections.Generic.List[object]'
$script:activeWatches = New-Object 'System.Collections.Generic.List[object]'
# A monotonic budget bounds the whole trial. The phone clock is corrected
# before this task starts and must not move while it runs, and a stopwatch
# keeps the bound even if the clock is corrected again by something else.
$budget = [Diagnostics.Stopwatch]::StartNew()
$budgetLimit = [TimeSpan]::FromMinutes(8)
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
    if ($Name -notmatch '^[a-zA-Z0-9-]+\.json$') {throw 'Invalid receipt name'}
    if ($Value -is [System.Collections.IDictionary] -and !$Value.Contains('attempt_id')) {$Value['attempt_id']=$script:attemptId}
    Write-TouchGpioJson (Join-Path $logs $Name) $Value
    Add-TouchGpioEvent (Join-Path $logs 'events.jsonl') @{event='receipt-committed';name=$Name;attempt_id=$script:attemptId;
        runner_id=$script:runnerId;utc=[DateTime]::UtcNow.ToString('o')}
}
function Set-WorkerPhase([string]$Phase) {
    Assert-Budget $Phase
    Save-Json 'worker-phase.json' @{phase=$Phase;attempt_id=$script:attemptId;elapsed_ms=$budget.ElapsedMilliseconds;utc=[DateTime]::UtcNow.ToString('o')}
}
function Collect-Phase([string]$Phase) {
    Set-WorkerPhase ('collect-'+$Phase)
    $dest = Join-Path $logs $Phase
    $null = New-Item -ItemType Directory -Path $dest
    $code = Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Collect-TimelmDiagnostics.ps1'),'-SkipEsp','-OutputRoot',$dest) `
        -StdoutPath (Join-Path $dest 'stdout.txt') -StderrPath (Join-Path $dest 'stderr.txt') -TimeoutMs 90000
    if ($code -ne 0) {throw "Collector $Phase returned $code"}
    $receipts = @(Get-ChildItem -LiteralPath $dest -Filter 'collection-status.json' -File -Recurse)
    if ($receipts.Count -ne 1) {throw "Collector receipt missing for $Phase"}
    return $receipts[0].DirectoryName
}
function Pnp([string]$Label, [string[]]$PnpArguments) {
    Set-WorkerPhase $Label
    Add-TouchGpioEvent (Join-Path $logs 'events.jsonl') @{event='pnp-begin';operation=$Label;attempt_id=$script:attemptId;runner_id=$script:runnerId;utc=[DateTime]::UtcNow.ToString('o')}
    $code = Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\pnputil.exe" -Arguments $PnpArguments `
        -StdoutPath (Join-Path $logs ($Label+'-stdout.txt')) -StderrPath (Join-Path $logs ($Label+'-stderr.txt')) -TimeoutMs 60000
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
        $state.exit_code=Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\logman.exe" `
            -Arguments @('create','trace',$state.session,'-pf',$state.providers,'-ets','-o',$state.output,'-mode','circular','-max','64') `
            -StdoutPath (Join-Path $logs 'trace-start-out.txt') -StderrPath (Join-Path $logs 'trace-start-err.txt') -TimeoutMs 10000
        $state.started=($state.exit_code -eq 0)
    } catch {
        $state.error = $_.Exception.Message
    }
    Save-Json 'live-trace-start.json' $state
    return $state
}
function Stop-LiveTrace($Trace) {
    if ($null -eq $Trace -or !$Trace.started) {return}
    try {
        $code=Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\logman.exe" -Arguments @('stop',$Trace.session,'-ets') `
            -StdoutPath (Join-Path $logs 'trace-stop-out.txt') -StderrPath (Join-Path $logs 'trace-stop-err.txt') -TimeoutMs 10000
        Save-Json 'live-trace-stop.json' @{session=$Trace.session;exit_code=$code;utc=[DateTime]::UtcNow.ToString('o')}
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
    $package = @($manifest.packages | Where-Object {$_.name -ceq $PackageName})[0]
    $infHash = @($manifest.files | Where-Object {$_.path -ceq ('Drivers/'+$PackageName+'/'+$package.inf)})[0].sha256
    $base = switch($PackageName){GPIO {'GPIO'} Host {'kona_geni'} Touch {'vhidmini'}}
    $sysHash = @($manifest.files | Where-Object {$_.path -ceq ('Drivers/'+$PackageName+'/'+$base+'.sys')})[0].sha256
    $selection = Get-TouchGpioSelectedPackage -RegistryRoot 'HKLM\SYSTEM' -ControlSet 'CurrentControlSet' `
        -DeviceId $DeviceId -WindowsRoot ($env:SystemDrive+'\') -InfHash $infHash -SysHash $sysHash -Service $base -FilterService:($PackageName -eq 'Touch')
    return $selection
}
function Assert-SelectedInf([string]$PackageName, [string]$DeviceId) {
    $selection = Get-SelectedInf $PackageName $DeviceId
    if (!$selection.matches) {throw "PnP retained an unexpected $PackageName driver; hardware activation refused"}
    Save-Json ('selected-'+$PackageName+'-inf.json') $selection
}
function Save-HostSnapshot([string]$Phase) {
    try {
        Add-TouchGpioEvent (Join-Path $logs 'events.jsonl') @{event='host-snapshot-begin';phase=$Phase;
            attempt_id=$script:attemptId;runner_id=$script:runnerId;utc=[DateTime]::UtcNow.ToString('o')}
        $snapshotFile=Join-Path $logs ('host-snapshot-'+$Phase+'-'+[guid]::NewGuid().ToString('N')+'.json')
        $code=Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$snapshotReader,'-RegistryPath',$hostKey,'-Output',$snapshotFile) `
            -StdoutPath ($snapshotFile+'.stdout.txt') -StderrPath ($snapshotFile+'.stderr.txt') -TimeoutMs 15000
        if($code -ne 0){throw "Registry snapshot child returned $code"}
        Add-TouchGpioEvent (Join-Path $logs 'events.jsonl') @{event='host-snapshot-read';phase=$Phase;
            attempt_id=$script:attemptId;runner_id=$script:runnerId;utc=[DateTime]::UtcNow.ToString('o')}
        $parameters = Get-Content -LiteralPath $snapshotFile -Raw | ConvertFrom-Json
        Save-Json 'host-parameters.json' $parameters
        Save-Json 'host-bitbang.json' @{phase=$Phase;attempt_id=$script:attemptId;
            attempt_recorded=$parameters.TimelmBitbangAttempt;backend=$parameters.TimelmHostBackend;
            epoch_low=$parameters.TimelmBitbangEpochLow;epoch_high=$parameters.TimelmBitbangEpochHigh;
            build_id=$parameters.TimelmBitbangBuildId;parameters=$parameters;utc=[DateTime]::UtcNow.ToString('o')}
    } catch {
        Add-TouchGpioEvent (Join-Path $logs 'events.jsonl') @{event='host-snapshot-failed';phase=$Phase;
            attempt_id=$script:attemptId;error=$_.Exception.Message;utc=[DateTime]::UtcNow.ToString('o')}
    }
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
    $plan = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'activation-plan.json') -Raw | ConvertFrom-Json
    if ($plan.schema -ne 2 -or $plan.mode -notin @('prepare','test') -or $plan.attempt_id -le 0 -or
        $plan.expected_build_id -ne 539365412) {throw 'Invalid activation plan'}
    $script:attemptId=[uint32]$plan.attempt_id
    $budgetLimit=if($plan.mode -eq 'prepare'){[TimeSpan]::FromMinutes(8)}else{[TimeSpan]::FromMinutes(10)}
    Set-WorkerPhase 'validate-baseline'
    Save-Json 'driver-attempt.json' @{attempt_id=$script:attemptId;runner_id=$script:runnerId;mode=$plan.mode;expected_build_id=$plan.expected_build_id;supervised=$true}
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
    # Offline stage chooses installation or test. The runner never changes
    # device gates and never restarts an active GPIO/host provider lifetime.
    Save-HostSnapshot 'entry'
    $before = Collect-Phase 'before'
    $tables = Get-Content -LiteralPath (Join-Path $before 'acpi-table-list.json') -Raw | ConvertFrom-Json
    if (@($tables.tables | Where-Object {$_.signature -eq 'IORT'}).Count) {throw 'Unexpected IORT; GPIO trial requires no SMMU owner change'}
    $ssdt = @(Get-ChildItem -LiteralPath $before -Filter '*SSDT*.dat' -File | Where-Object {(Get-FileHash -LiteralPath $_.FullName).Hash -eq $manifest.ssdt_sha256})
    if ($ssdt.Count -ne 1) {throw 'Expected GPIO-only trial SSDT missing'}
    $previousGates=@{host=(Get-Gate $hostKey 'NativeGpioI2cEnabled');provider=(Get-Gate $gpioKey 'TouchBusGpioEnabled')}
    Save-Json 'gates-before.json' $previousGates
    foreach($name in $gates) {if((Get-Gate $hostKey $name) -ne 0){throw ('Pre-existing hardware gate enabled: '+$name)}}
    $target=if($plan.mode -eq 'test'){1}else{0}
    if($plan.host_gate -ne $target -or $plan.provider_gate -ne $target -or
        $previousGates.host -ne $target -or $previousGates.provider -ne $target) {throw 'Offline activation plan/gate mismatch'}
    $gpio = Get-TouchGpioDevice $gpioId
    if($gpio.ConfigManagerErrorCode -ne 0 -or $gpio.Service -ine 'GPIO'){throw 'Unexpected initial GPIO provider state'}
    foreach ($p in $manifest.packages) {
        $pattern = switch ($p.name) {GPIO {'ACPI\\KONA1001'} Host {'ACPI\\TIML0001'} Touch {'ACPI\\LGSW4290'}}
        $newHash = @($manifest.files | Where-Object {$_.path -ceq ('Drivers/'+$p.name+'/'+$p.inf)})[0].sha256
        $allowed = @($p.replaces_inf_sha256) + @($newHash)
        foreach ($entry in @(Get-ChildItem -LiteralPath "$env:SystemRoot\INF" -Filter '*.inf' -File | Select-String -Pattern $pattern -List)) {
            if ((Get-FileHash -LiteralPath $entry.Path).Hash -notin $allowed) {throw "Unexpected installed $($p.name) INF"}
        }
    }
    $liveTrace = Start-LiveTrace
    if($plan.mode -eq 'prepare') {
        foreach ($cert in $certificates) {
            foreach ($storeName in @('Root','TrustedPublisher')) {
                $store=New-Object Security.Cryptography.X509Certificates.X509Store($storeName,'LocalMachine')
                try {$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite);$store.Add($cert)}finally{$store.Close()}
            }
            $cert.Reset()
        }
        # INSTALL_AS_SET deliberately keeps the currently running drivers.
        # Exact selection is checked after normal shutdown, never forged here.
        Save-Json 'selection-before-GPIO.json' (Get-SelectedInf 'GPIO' $gpioId)
        Save-Json 'selection-before-Host.json' (Get-SelectedInf 'Host' $hostId)
        Set-WorkerPhase 'defer-driver-set'
        $deferredCode=Invoke-ProbeProcess -Executable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Install-TouchGpioDeferred.ps1')) `
            -StdoutPath (Join-Path $logs 'deferred-stdout.txt') -StderrPath (Join-Path $logs 'deferred-stderr.txt') -TimeoutMs 90000
        if($deferredCode -ne 0){throw "Deferred installer returned $deferredCode"}
        $deferred=Get-Content (Join-Path $logs 'deferred-result.json') -Raw | ConvertFrom-Json
        if($deferred.attempt_id -ne $script:attemptId -or !$deferred.api_success -or
            $deferred.method -ne 'DiInstallDriverW/INSTALL_AS_SET' -or $deferred.flags -ne 64 -or
            $deferred.selected_driver_proven -ne $false){throw 'Invalid deferred install receipt'}
        $operations.Add([ordered]@{operation='defer-GPIO-Host';exit_code=0;method=$deferred.method;flags=64;utc=[DateTime]::UtcNow.ToString('o')})
        Save-Json 'operations.json' @($operations.ToArray())
        Copy-SetupApiLog 'after-deferred-set'
        Pnp 'stage-Touch' @('/add-driver',(Join-Path $PSScriptRoot 'Drivers\Touch\vhidmini.inf'))
        $needNextBoot=$true
        Save-Json 'prepared.json' @{mode='prepare';method='deferred-driver-set';attempt_id=$script:attemptId;
            next_step='Normal shutdown activates the set; reconnect mass storage and verify selected INF/SYS before a new attempt';
            hardware_tested=$false;selected_driver_proven=$false}
        Set-WorkerPhase 'prepare-staged'
        Wait-Seconds 10 'prepare-screenshot-grace'
    } else {
        Assert-SelectedInf 'GPIO' $gpioId
        Assert-SelectedInf 'Host' $hostId
        $requested=Get-Gate $gpioKey 'TouchBusGpioEnabled'
        $effective=Get-Gate $gpioKey 'TimelmGpioBitbangGate'
        Save-Json 'provider-gates-after-restart.json' @{TouchBusGpioEnabled=$requested;TimelmGpioBitbangGate=$effective;phase='cold-boot-no-restart'}
        Assert-TouchGpioProviderGate $requested $effective
        Save-HostSnapshot 'cold-boot-before-acceptance'
        $parameters=Get-ItemProperty -LiteralPath $hostKey
        Assert-TouchGpioHostEvidence $parameters $script:attemptId ([uint32]$plan.expected_build_id)
        $hostDevice=Get-TouchGpioDevice $hostId
        if($hostDevice.ConfigManagerErrorCode -ne 0 -or $hostDevice.Service -ine 'kona_geni') {throw 'GPIO I2C host did not start; inspect first failure'}
        Save-Json 'phase-host-started.json' @{phase='host-started';code=0;service=$hostDevice.Service;mode='cold-boot';attempt_id=$script:attemptId}
        Pnp 'install-Touch' @('/add-driver',(Join-Path $PSScriptRoot 'Drivers\Touch\vhidmini.inf'),'/install')
        Copy-SetupApiLog 'after-touch-install'
        $touchDevices=@(Get-CimInstance Win32_PnPEntity | Where-Object {$_.PNPDeviceID -like 'ACPI\LGSW4290\*'})
        if($touchDevices.Count -ne 1){throw 'Expected exactly one SW42902 device after client installation'}
        Assert-SelectedInf 'Touch' $touchDevices[0].PNPDeviceID
        if($touchDevices[0].ConfigManagerErrorCode -ne 0){throw 'Touch client did not start'}
        $testWindow=$true
        Save-Json 'touch-window.json' @{utc=[DateTime]::UtcNow.ToString('o');seconds=120;instruction='Try taps and swipes. Automatic normal shutdown follows log collection.'}
        Save-Json 'phase-test-window.json' @{phase='test-window';seconds=120;device=$touchDevices[0].PNPDeviceID}
    }
} catch {
    $trialError = $_.Exception.Message
    try{Set-WorkerPhase 'trial-error'}catch{}
    Save-HostSnapshot 'exception'
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
    Save-HostSnapshot 'final'
    $after = Collect-Phase 'after'
    Save-Json 'complete.json' @{mode=$plan.mode;after=$after;error=$trialError;need_next_boot=$needNextBoot;shutdown_pending=$true;shutdown_owner='supervisor';utc=[DateTime]::UtcNow.ToString('o')}
} catch {Save-Json 'collection-failed.json' @{error=$_.Exception.Message;trial_error=$trialError;utc=[DateTime]::UtcNow.ToString('o')}}
finally {if ($awake) {[TouchGpioAwake]::Release();$awake = $false}
    foreach ($watch in @($script:activeWatches.ToArray())) {Stop-NodeWatch $watch}}
Save-Json 'operations.json' @($operations.ToArray())
# Parent supervisor requests shutdown even if this worker throws or blocks.
