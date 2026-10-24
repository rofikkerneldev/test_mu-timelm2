# Production helper behavioral tests, isolated files and mocked registry reads.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('timelm-contracts-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
function Expect-Refusal([scriptblock]$Action) {
    $failed=$false;try{&$Action}catch{$failed=$true}
    if(!$failed){throw 'An unsafe/missing contract was accepted'}
}
try {
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
    'PASS: exact selected binding/SYS, strict gates, stale/missing attempt/build/epoch rejection, atomic JSON and interrupted-write isolation'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase) -or
        $resolved.Substring($expectedParent.Length) -notmatch '^timelm-contracts-[a-f0-9]{32}$') {throw 'Unsafe contract test cleanup'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
