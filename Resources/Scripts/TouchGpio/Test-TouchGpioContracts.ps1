# Production helper behavioral tests, isolated files and mocked registry reads.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
$probeScript=Join-Path $PSScriptRoot 'Invoke-ProbeProcess.ps1'
if(!(Test-Path -LiteralPath $probeScript)){$probeScript=Join-Path $PSScriptRoot '../TouchEnumeration/Invoke-ProbeProcess.ps1'}
. $probeScript
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('timelm-contracts-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
function Expect-Refusal([scriptblock]$Action) {
    $failed=$false;try{&$Action}catch{$failed=$true}
    if(!$failed){throw 'An unsafe/missing contract was accepted'}
}
try {
    $helpers=@(Get-TouchGpioHelperSources $PSScriptRoot)
    if(@($helpers | Where-Object {$_.Name -eq 'Invoke-ProbeProcess.ps1'}).Count -ne 1 -or
        @($helpers | Where-Object {$_.Name -eq 'Collect-TimelmDiagnostics.ps1'}).Count -ne 1) {throw 'Required runtime helper sources missing'}
    $infRoot=Join-Path $testRoot 'Windows/INF'
    $sysRoot=Join-Path $testRoot 'Windows/System32/DriverStore/FileRepository/host'
    $null=New-Item -ItemType Directory -Path $infRoot,$sysRoot -Force
    [IO.File]::WriteAllText((Join-Path $infRoot 'oem1.inf'),'old INF')
    [IO.File]::WriteAllText((Join-Path $infRoot 'oem2.inf'),'new INF')
    [IO.File]::WriteAllText((Join-Path $sysRoot 'kona_geni.sys'),'new SYS')
    $infHash=(Get-FileHash -LiteralPath (Join-Path $infRoot 'oem2.inf')).Hash
    $sysHash=(Get-FileHash -LiteralPath (Join-Path $sysRoot 'kona_geni.sys')).Hash
    $state=@{driver='{4d36e97d-e325-11ce-bfc1-08002be10318}\0016';service='kona_geni';image='System32\DriverStore\FileRepository\host\kona_geni.sys';queries=@()}
    $query={param($Key)
        $state.queries+=,$Key
        if($Key -like '*\Enum\*'){return @(('    Driver    REG_SZ    '+$state.driver),('    Service    REG_SZ    '+$state.service))}
        if($Key -like '*\Class\*') {
            $name=if($Key -like '*\0016'){'oem1.inf'}elseif($Key -like '*\0017'){'oem2.inf'}else{throw 'No exact Class reference'}
            return @(('    InfPath    REG_SZ    '+$name),'    MatchingDeviceId    REG_SZ    ACPI\TIML0001')
        }
        if($Key -like '*\Services\*'){return ('    ImagePath    REG_EXPAND_SZ    '+$state.image)}
        throw 'Unexpected or recursive registry query'
    }.GetNewClosure()
    $args=@{RegistryRoot='HKLM\TEST';ControlSet='ControlSet001';DeviceId='ACPI\TIML0001\e';WindowsRoot=$testRoot;InfHash=$infHash;SysHash=$sysHash;Service='kona_geni';Query=$query}
    $old=Get-TouchGpioSelectedPackage @args
    if($old.matches -or $state.queries -match '\\0017$'){throw 'Unselected bundle node was accepted or scanned'}
    $state.driver='{4d36e97d-e325-11ce-bfc1-08002be10318}\0017'
    $new=Get-TouchGpioSelectedPackage @args
    if(!$new.matches -or $new.node -ne $state.driver){throw ('Exact selected binding was rejected: '+$new.reason)}
    $args.SysHash='0'*64;if((Get-TouchGpioSelectedPackage @args).matches){throw 'Wrong selected SYS accepted'};$args.SysHash=$sysHash
    $state.service='other';if((Get-TouchGpioSelectedPackage @args).matches){throw 'Wrong service accepted'};$state.service='kona_geni'
    $state.driver='';if((Get-TouchGpioSelectedPackage @args).matches){throw 'Missing Enum Driver accepted'}
    $state.driver='..\0017';if((Get-TouchGpioSelectedPackage @args).matches){throw 'Malformed Enum Driver accepted'}
    foreach($effective in @($null,0,2)) {Expect-Refusal {Assert-TouchGpioProviderGate 1 $effective}}
    Expect-Refusal {Assert-TouchGpioProviderGate $null 1}
    Assert-TouchGpioProviderGate 1 1
    $good=@{TimelmBitbangAttempt=7;TimelmBitbangBuildId=539365412;TimelmHostBuildId=539365412;
        TimelmHostBackend=1;TimelmBitbangSchema=2;TimelmBitbangSnapshotValid=1;TimelmBitbangStage=4;
        TimelmBitbangStatus=0;TimelmBitbangProviderGate=1;TimelmBitbangProviderStatus=0;
        TimelmBitbangEpochLow=123;TimelmBitbangEpochHigh=0;TimelmBitbangProviderEpochLow=456;TimelmBitbangProviderEpochHigh=0}
    Assert-TouchGpioHostEvidence ([pscustomobject]$good) 7 539365412
    foreach($name in @($good.Keys)) {
        $bad=$good.Clone();$bad.Remove($name)
        Expect-Refusal {Assert-TouchGpioHostEvidence ([pscustomobject]$bad) 7 539365412}
    }
    foreach($change in @(@('TimelmBitbangAttempt',8),@('TimelmHostBackend',3),@('TimelmBitbangBuildId',1),
        @('TimelmBitbangSnapshotValid',0),@('TimelmBitbangStage',2),@('TimelmBitbangProviderGate',2),@('TimelmBitbangEpochLow',0))) {
        $bad=$good.Clone();$bad[$change[0]]=$change[1]
        Expect-Refusal {Assert-TouchGpioHostEvidence ([pscustomobject]$bad) 7 539365412}
    }
    $receipt=Join-Path $testRoot 'receipt.json'
    Write-TouchGpioJson $receipt @{attempt_id=7;phase='before'}
    Write-TouchGpioJson $receipt @{attempt_id=7;phase='after'}
    $read=Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    if($read.phase -ne 'after'){throw 'Atomic replacement failed'}
    [IO.File]::WriteAllBytes(($receipt+'.interrupted.pending'),[byte[]](0,0,0))
    if((Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json).phase -ne 'after'){throw 'Interrupted temporary write changed committed receipt'}
    Write-TouchGpioJson (Join-Path $testRoot 'array.json') @(@{operation='single'})
    if(!(Get-Content -LiteralPath (Join-Path $testRoot 'array.json') -Raw).TrimStart().StartsWith('[')){throw 'One-element array lost its JSON shape'}
    # Regression: the real provider object contains a deep PSDrive/PSProvider
    # reflection graph. R13 stalled before installation while encoding it.
    $raw=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
    Expect-Refusal {Write-TouchGpioJson (Join-Path $testRoot 'raw-registry.json') $raw}
    if(Test-Path (Join-Path $testRoot 'raw-registry.json')) {throw 'Raw registry object was published'}
    $flat=ConvertTo-TouchGpioRegistryValues $raw
    Write-TouchGpioJson (Join-Path $testRoot 'flat-registry.json') $flat
    $flatJson=Get-Content -LiteralPath (Join-Path $testRoot 'flat-registry.json') -Raw
    if($flatJson -match '"PS(?:Path|ParentPath|ChildName|Drive|Provider)"' -or $flatJson.Length -gt 32768) {throw 'Registry provider metadata escaped projection'}
    $typed=[pscustomobject]@{SignedDword=-1;Qword=[long]4294967297;Binary=[byte[]](0,128,255);Multi=[string[]]@('one','two')}
    $typed | Add-Member ScriptProperty PSDrive {throw 'Metadata getter must never run'}
    $projected=ConvertTo-TouchGpioRegistryValues $typed
    Write-TouchGpioJson (Join-Path $testRoot 'typed-registry.json') $projected
    $roundtrip=Get-Content -LiteralPath (Join-Path $testRoot 'typed-registry.json') -Raw | ConvertFrom-Json
    if($roundtrip.SignedDword -ne -1 -or $roundtrip.Qword -ne 4294967297 -or
        ($roundtrip.Binary -join ',') -ne '0,128,255' -or ($roundtrip.Multi -join ',') -ne 'one,two') {throw 'Registry value types were lost'}
    Expect-Refusal {ConvertTo-TouchGpioRegistryValues ([pscustomobject]@{Bad=[IO.MemoryStream]::new()})}
    # Execute the production snapshot functions only, without the ARM64 runner
    # entry point. This catches a producer accidentally passing the raw object.
    $tokens=$null;$errors=$null
    $runnerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-TouchGpioTrial.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Runner parse failed'}
    foreach($name in @('Save-Json','Save-HostSnapshot')) {
        $definition=$runnerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        if(!$definition){throw 'Production snapshot function missing'}
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $logs=Join-Path $testRoot 'snapshot';$null=New-Item -ItemType Directory -Path $logs
    $hostKey='HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
    $snapshotReader=Join-Path $PSScriptRoot 'Export-TouchGpioRegistryValues.ps1'
    $script:attemptId=7;$script:runnerId='snapshot-regression'
    Save-HostSnapshot 'entry'
    $snapshot=Get-Content (Join-Path $logs 'host-bitbang.json') -Raw | ConvertFrom-Json
    if($snapshot.phase -ne 'entry' -or $snapshot.attempt_id -ne 7 -or
        $snapshot.parameters.PSObject.Properties.Name -contains 'PSDrive') {throw 'Production snapshot did not publish plain registry values'}
    $events=Get-Content (Join-Path $logs 'events.jsonl') | ForEach-Object {$_ | ConvertFrom-Json}
    if(@($events | Where-Object {$_.event -eq 'host-snapshot-read'}).Count -ne 1 -or
        @($events | Where-Object {$_.event -eq 'host-snapshot-failed'}).Count) {throw 'Production snapshot read/publish failed'}
    # Supervision uses the production bounded process helper, but the shutdown
    # callback only records calls. No shutdown command or phone task is run.
    $exe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $probe=@{calls=0}
    $shutdown={ $probe.calls++ }
    $superArgs=@{Executable=$exe;StdoutPath=(Join-Path $testRoot 'worker-out.txt');StderrPath=(Join-Path $testRoot 'worker-err.txt');
        StatePath=(Join-Path $testRoot 'supervisor.json');AttemptId=7;TimeoutMs=5000;RequestShutdown=$shutdown}
    $exited=Invoke-TouchGpioSupervisedWorker @superArgs -Arguments @('-NoProfile','-Command','exit 7')
    if($exited.worker_exit_code -ne 7 -or !$exited.shutdown_requested -or $probe.calls -ne 1){throw 'Worker nonzero exit prevented shutdown'}
    $superArgs.TimeoutMs=200
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $blocked=Invoke-TouchGpioSupervisedWorker @superArgs -Arguments @('-NoProfile','-Command','Start-Sleep -Seconds 60')
    if($blocked.phase -ne 'worker-failed' -or $blocked.worker_error -notmatch 'time limit' -or
        !$blocked.shutdown_requested -or $probe.calls -ne 2 -or $timer.ElapsedMilliseconds -gt 8000){throw 'Worker deadline failed to reach shutdown callback'}
    $superArgs.TimeoutMs=5000;$superArgs.Executable=Join-Path $testRoot 'missing-worker.exe'
    $missing=Invoke-TouchGpioSupervisedWorker @superArgs -Arguments @('missing')
    if(!$missing.worker_error -or !$missing.shutdown_requested -or $probe.calls -ne 3){throw 'Worker launch failure prevented shutdown'}
    $superArgs.StatePath=Join-Path $testRoot 'missing-parent/state.json'
    $unwritable=Invoke-TouchGpioSupervisedWorker @superArgs -Arguments @('missing')
    if(!$unwritable.shutdown_requested -or $probe.calls -ne 4){throw 'Receipt failure prevented shutdown'}
    $superArgs.StatePath=Join-Path $testRoot 'supervisor.json';$superArgs.RequestShutdown={throw 'injected shutdown failure'}
    $refused=Invoke-TouchGpioSupervisedWorker @superArgs -Arguments @('missing')
    if($refused.shutdown_requested -or $refused.shutdown_error -ne 'injected shutdown failure'){throw 'Shutdown failure was hidden'}
    # Production heartbeat must survive a running child and diagnostic failure.
    $superArgs.Executable=$exe;$superArgs.RequestShutdown=$shutdown;$superArgs.TimeoutMs=5000
    $running=Invoke-TouchGpioSupervisedWorker @superArgs -Arguments @('-NoProfile','-Command','Start-Sleep -Milliseconds 800; exit 0')
    if($running.worker_exit_code -ne 0 -or $running.heartbeat_count -lt 1 -or !$running.worker_pid){throw 'Running child heartbeat not persisted'}
    $code=Invoke-ProbeProcess -Executable $exe -Arguments @('-NoProfile','-Command','Start-Sleep -Milliseconds 300; exit 0') `
        -StdoutPath $superArgs.StdoutPath -StderrPath $superArgs.StderrPath -TimeoutMs 5000 -OnProgress {throw 'diagnostic failure'}
    if($code -ne 0){throw 'Diagnostic failure changed process result'}
    . (Join-Path $PSScriptRoot 'TouchGpioDeferred.ps1')
    & {
        $fake=[pscustomobject]@{files=@()}
        $packageRoot=Join-Path $testRoot 'deferred-source';$null=New-Item -ItemType Directory $packageRoot
        foreach($kind in @('GPIO','Host')){
            $dir=Join-Path $packageRoot ('Drivers/'+$kind);$null=New-Item -ItemType Directory $dir
            foreach($ext in @('inf','cat','sys')){
                $name=if($kind -eq 'GPIO'){'GPIO'}else{'kona_geni'}
                $relative='Drivers/'+$kind+'/'+$name+'.'+$ext
                Set-Content -LiteralPath (Join-Path $packageRoot $relative) -Value ($relative+'-fixture')
                $fake.files+=@{path=$relative;sha256=(Get-FileHash (Join-Path $packageRoot $relative)).Hash}
            }
        }
        # The manifest loader is already tested independently; inject only its
        # result to test production copy/flag/error behavior without any driver API.
        function Get-TouchGpioManifest {param($Root) return $fake}
        $apiProbe=@{calls=0}
        $api={param($directory,$flags)
            $apiProbe.calls++
            if($flags -ne 64 -or @(Get-ChildItem $directory -File).Count -ne 6){throw 'Wrong set or unsafe API flags'}
            return @{success=$true;need_reboot=$false;win32_error=0}
        }
        $params=@{Root=$packageRoot;Destination=(Join-Path $testRoot 'deferred-set');AttemptId=7;OsBuild=19041;Install=$api}
        $result=Invoke-TouchGpioDeferredInstall @params
        if(!$result.api_success -or $result.selected_driver_proven -or $result.flags -ne 64 -or $apiProbe.calls -ne 1){throw 'Deferred staging mistaken for selection'}
        Expect-Refusal {Invoke-TouchGpioDeferredInstall @params}
        $params.Destination=Join-Path $testRoot 'deferred-old-os';$params.OsBuild=15063
        Expect-Refusal {Invoke-TouchGpioDeferredInstall @params}
        $params.OsBuild=19041;$params.Destination=Join-Path $testRoot 'deferred-api-fail';$params.Install={@{success=$false;win32_error=5}}
        Expect-Refusal {Invoke-TouchGpioDeferredInstall @params}
        $params.Destination=Join-Path $testRoot 'deferred-tamper';$params.Install=$api
        Add-Content -LiteralPath (Join-Path $packageRoot $fake.files[0].path) -Value 'tampered'
        Expect-Refusal {Invoke-TouchGpioDeferredInstall @params}
        if($apiProbe.calls -ne 1){throw 'Rejected set reached installation API'}
    }
    'PASS: exact binding/SYS, strict gates, attempt/build/epoch, atomic JSON, isolated plain registry snapshot, worker exit/timeout/launch/receipt failures and shutdown failure evidence'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase) -or
        $resolved.Substring($expectedParent.Length) -notmatch '^timelm-contracts-[a-f0-9]{32}$') {throw 'Unsafe contract test cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
