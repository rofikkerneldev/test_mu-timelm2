# Behavioral regression checks. No phone or hardware access.
param([string]$Artifact)
$ErrorActionPreference='Stop'
if($env:PROCESSOR_ARCHITECTURE -eq 'ARM64'){throw 'Run tests on the build PC'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
. (Join-Path $PSScriptRoot 'Analyze-TouchGpioResult.ps1')
function Remove-TouchGpioTestItem {
    param([string]$LiteralPath,[switch]$Recurse,[switch]$Force)
    $path=[IO.Path]::GetFullPath($LiteralPath)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(!$path.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or
       $path.Substring($temp.Length) -notmatch '^timelm-gpio-(result|empty)-[a-f0-9]{8}(\\|$)'){throw 'Unsafe test cleanup path'}
    Remove-Item -LiteralPath $path -Recurse:$Recurse -Force:$Force
}
foreach($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors){throw ($errors|Out-String)}
}
foreach($name in @('Launch-TouchGpioTrial.ps1','Run-TouchGpioTrial.ps1','Invoke-TouchGpioSupervised.ps1','TouchGpioDeviceManager.ps1')) {
    $refused=$false
    try {& (Join-Path $PSScriptRoot $name)}catch{if($_.Exception.Message -ne 'Wrong machine'){throw};$refused=$true}
    if(!$refused){throw 'Machine guard did not refuse this PC'}
}
& (Join-Path $PSScriptRoot 'Test-TouchGpioContracts.ps1')
if($Artifact){$null=Get-TouchGpioManifest $Artifact}
function Get-SyntheticHash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')} finally {$sha.Dispose()}
    } finally {$stream.Dispose()}
}
function New-SyntheticEvidence([string]$Root, [bool]$Good, [int]$FirstPinId = 1) {
    foreach ($folder in @('boot','runtime\before\20261021T000000Z-test','runtime\after\20261021T000000Z-test')) {
        $null = [IO.Directory]::CreateDirectory((Join-Path $Root $folder))
    }
    Set-Content -LiteralPath (Join-Path $Root 'boot\timelm-touch-gpio.txt') -Value @(
        'timelm GPIO I2C touch trial v1',
        'Restore original Windows FIRST.',
        'Restore status=0x0000000000000000',
        'Enumeration namespace gate=0x0000000000000000',
        'Install enumeration SSDT=0x0000000000000000',
        'Enumeration table readback=0x0000000000000000',
        'Windows stage: BEFORE StartImage (original Windows Boot Manager).')
    $ssdtPath = Join-Path $Root 'runtime\before\20261021T000000Z-test\SSDT.dat'
    [IO.File]::WriteAllBytes($ssdtPath,[Text.Encoding]::ASCII.GetBytes('SSDTsynthetic'))
    $ssdtHash = Get-SyntheticHash $ssdtPath
    [ordered]@{schema=1;trial='touch-gpio-v1';ssdt_sha256=$ssdtHash;files=@();packages=@()} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Root 'runtime\package.json')
    Set-Content -LiteralPath (Join-Path $Root 'runtime\attempt.json') -Value '{"utc":"2026-10-21T00:00:00Z"}'
    [ordered]@{tables=@([ordered]@{id=1413763923;signature='SSDT';count=1})} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Root 'runtime\before\20261021T000000Z-test\acpi-table-list.json')
    foreach ($name in @('GPIO','Host','Touch')) {
        [ordered]@{device='ACPI\TEST\'+$name;inf='oem1.inf';matches=$true;sha256='00'} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root ('runtime\selected-' + $name + '-inf.json'))
    }
    [ordered]@{operation='install-GPIO';exit_code=0;utc='2026-10-21T00:00:00Z'} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'runtime\operations.json')
    [ordered]@{utc='2026-10-21T00:00:00Z';seconds=120} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'runtime\touch-window.json')
    [ordered]@{before_utc='2026-10-21T00:00:00Z';after_utc='2026-10-21T00:00:00Z';host_utc='2026-10-21T00:00:00Z'} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'runtime\clock.json')
    [ordered]@{after='runtime\after\20261021T000000Z-test';error=$null;need_next_boot=$false;normal_shutdown=$true;utc='2026-10-21T00:00:00Z'} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'runtime\complete.json')
    $identity0 = [uint32]0; $identity1 = [uint32]0
    $expected = [Text.Encoding]::ASCII.GetBytes('B3W68TIM')
    for ($i = 0; $i -lt 4; ++$i) {$identity0 = $identity0 -bor ([uint32]$expected[$i] -shl (8*$i))}
    for ($i = 0; $i -lt 4; ++$i) {$identity1 = $identity1 -bor ([uint32]$expected[4+$i] -shl (8*$i))}
    if (!$Good) {$identity0 = $identity0 -bxor 0x01}
    $values = @(
        [ordered]@{device='TIML0001';name='TimelmBitbangStage';value=4},
        [ordered]@{device='TIML0001';name='TimelmBitbangPinCount';value=5},
        [ordered]@{device='TIML0001';name='TimelmBitbangPinId0';value=$FirstPinId},
        [ordered]@{device='TIML0001';name='TimelmBitbangPinId1';value=2},
        [ordered]@{device='TIML0001';name='TimelmBitbangPinId2';value=3},
        [ordered]@{device='TIML0001';name='TimelmBitbangPinId3';value=4},
        [ordered]@{device='TIML0001';name='TimelmBitbangPinId4';value=5},
        [ordered]@{device='TIML0001';name='TimelmBitbangIdleLines';value=3},
        [ordered]@{device='TIML0001';name='TimelmBitbangIdentityStatus';value=0},
        [ordered]@{device='TIML0001';name='TimelmBitbangIdentity0';value=$identity0},
        [ordered]@{device='TIML0001';name='TimelmBitbangIdentity1';value=$identity1},
        [ordered]@{device='TIML0001';name='TimelmBitbangStatus';value=0},
        [ordered]@{device='LGSW4290';name='TimelmTouchStartStatus';value=0},
        [ordered]@{device='LGSW4290';name='TimelmTouchProductId';value=@($expected)},
        [ordered]@{device='LGSW4290';name='TimelmTouchIrqs';value=7},
        [ordered]@{device='LGSW4290';name='TimelmTouchDecoded';value=5})
    foreach($pair in @(@('TimelmHostBackend',1),@('TimelmHostBuildId',539365412),@('TimelmBitbangBuildId',539365412),
        @('TimelmBitbangSchema',2),@('TimelmBitbangAttempt',7),@('TimelmBitbangEpochLow',123),@('TimelmBitbangEpochHigh',0),
        @('TimelmBitbangProviderEpochLow',456),@('TimelmBitbangProviderEpochHigh',0),@('TimelmBitbangSnapshotValid',1),
        @('TimelmBitbangProviderGate',1),@('TimelmBitbangProviderStatus',0))) {
        $values += [ordered]@{device='TIML0001';name=$pair[0];value=$pair[1]}
    }
    foreach($i in 0..4) {
        $values += [ordered]@{device='TIML0001';name=('TimelmBitbangPinIdHigh'+$i);value=0}
        $values += [ordered]@{device='TIML0001';name=('TimelmBitbangConnOrdinal'+$i);value=($i+1)}
    }
    Write-TouchGpioJson (Join-Path $Root 'runtime/driver-attempt.json') @{attempt_id=7;expected_build_id=539365412;mode='test'}
    Write-TouchGpioJson (Join-Path $Root 'runtime/provider-gates-after-restart.json') @{TouchBusGpioEnabled=1;TimelmGpioBitbangGate=1}
    ConvertTo-Json -InputObject $values -Depth 5 |
        Set-Content -LiteralPath (Join-Path $Root 'runtime\after\20261021T000000Z-test\touch-driver-diagnostics.json')
    $entities = @(
        [ordered]@{PNPDeviceID='ACPI\TIML0001\0';ConfigManagerErrorCode=0},
        [ordered]@{PNPDeviceID='ACPI\LGSW4290\0';ConfigManagerErrorCode=0})
    ConvertTo-Json -InputObject $entities -Depth 5 |
        Set-Content -LiteralPath (Join-Path $Root 'runtime\after\20261021T000000Z-test\pnp-entities.json')
}
$syntheticRoot = Join-Path ([IO.Path]::GetTempPath()) ('timelm-gpio-result-' + [guid]::NewGuid().ToString('N').Substring(0,8))
try {
    New-SyntheticEvidence $syntheticRoot $true
    $accepted = Get-TouchGpioResult -Root $syntheticRoot
    if ($accepted.verdict -ne 'hardware-chain-proven-awaiting-user-confirmation') {throw "Unexpected synthetic verdict: $($accepted.verdict)"}
    $confirmed = Get-TouchGpioResult -Root $syntheticRoot -TapSwipeObserved $true
    if ($confirmed.verdict -ne 'accepted') {throw "Unexpected confirmed verdict: $($confirmed.verdict)"}
    if ($confirmed.steps['tap-and-swipe'].status -ne 'proven') {throw 'The user confirmation was not recorded'}
    Write-TouchGpioJson (Join-Path $syntheticRoot 'runtime/driver-attempt.json') @{attempt_id=7;expected_build_id=539365412;mode='test';supervised=$true}
    $noSupervisor=Get-TouchGpioResult -Root $syntheticRoot
    if($noSupervisor.verdict -ne 'incomplete'){throw 'Missing supervisor receipt was accepted'}
    $supervisor=@{attempt_id=7;phase='worker-exited';worker_exit_code=0;worker_error=$null;shutdown_requested=$true;shutdown_error=$null}
    Write-TouchGpioJson (Join-Path $syntheticRoot 'runtime/supervisor.json') $supervisor
    if((Get-TouchGpioResult -Root $syntheticRoot).steps['supervisor-shutdown-request'].status -ne 'proven'){throw 'Matching supervisor receipt rejected'}
    foreach($change in @(@('attempt_id',8),@('worker_error','deadline'),@('worker_exit_code',$null),@('shutdown_requested',$false))) {
        $bad=$supervisor.Clone();$bad[$change[0]]=$change[1]
        Write-TouchGpioJson (Join-Path $syntheticRoot 'runtime/supervisor.json') $bad
        if((Get-TouchGpioResult -Root $syntheticRoot).verdict -ne 'incomplete'){throw 'Failed/stale supervisor receipt was accepted'}
    }
    Write-TouchGpioJson (Join-Path $syntheticRoot 'runtime/driver-attempt.json') @{attempt_id=8;expected_build_id=539365412;mode='test'}
    $stale=Get-TouchGpioResult -Root $syntheticRoot
    if($stale.verdict -ne 'incomplete' -or $stale.steps['fresh-host-evidence'].status -ne 'failed'){throw 'Stale attempt was accepted by the analyzer'}
    New-SyntheticEvidence $syntheticRoot $true
    [IO.File]::WriteAllBytes((Join-Path $syntheticRoot 'runtime/provider-gates-after-restart.json'),[byte[]](0,0,0))
    $nul=Get-TouchGpioResult -Root $syntheticRoot
    if($nul.verdict -ne 'incomplete' -or $nul.steps['valid-runtime-receipts'].status -ne 'failed'){throw 'NUL receipt was accepted by the analyzer'}
    New-SyntheticEvidence $syntheticRoot $true
    Remove-TouchGpioTestItem -LiteralPath (Join-Path $syntheticRoot 'runtime\after') -Recurse -Force
    $empty = Get-TouchGpioResult -Root $syntheticRoot
    if ($empty.verdict -ne 'incomplete') {throw "Missing evidence was accepted: $($empty.verdict)"}
    New-SyntheticEvidence $syntheticRoot $false
    $wrong = Get-TouchGpioResult -Root $syntheticRoot
    if ($wrong.verdict -ne 'incomplete' -or $wrong.steps['chip-identity'].status -ne 'missing') {
        throw 'A wrong chip identity was accepted'
    }
    # A GPIO connection resource that does not match the SSDT pin contract must
    # be rejected even when every other step is proven. The synthetic tree is
    # rebuilt with the wrong pin instead of editing the JSON, because Windows
    # PowerShell 5.1 rewrites a parsed array as {"value":[...]}.
    New-SyntheticEvidence $syntheticRoot $true 0
    $badShape = Get-TouchGpioResult -Root $syntheticRoot
    if ($badShape.verdict -ne 'incomplete' -or $badShape.steps['gpio-resource-shape'].status -ne 'failed') {
        throw 'An unexpected GPIO connection resource was accepted'
    }
    # The Windows PowerShell 5.1 collector can serialize the diagnostic array
    # as {"value":[...],"Count":N}. That shape must still be read as evidence.
    New-SyntheticEvidence $syntheticRoot $true
    $diagnosticsPath = Join-Path $syntheticRoot 'runtime\after\20261021T000000Z-test\touch-driver-diagnostics.json'
    $inner = (Get-Content -LiteralPath $diagnosticsPath -Raw).Trim()
    $innerCount = @($inner | ConvertFrom-Json).Count
    Set-Content -LiteralPath $diagnosticsPath -Value ('{"value":' + $inner + ',"Count":' + $innerCount + '}')
    $wrapped = Get-TouchGpioResult -Root $syntheticRoot
    if ($wrapped.verdict -ne 'hardware-chain-proven-awaiting-user-confirmation' -or
        $wrapped.steps['chip-identity'].status -ne 'proven') {
        throw 'A wrapped diagnostic array was not read as evidence'
    }
    # The same wrap can appear around the binary product id of the touch
    # device. It must still be read as the panel identity.
    $text = Get-Content -LiteralPath $diagnosticsPath -Raw
    $text = [regex]::Replace($text,
        '("name"\s*:\s*"TimelmTouchProductId"\s*,\s*"value"\s*:\s*)\[[^\]]*\]',
        '$1{"value":[66,51,87,54,56,84,73,77],"Count":8}')
    Set-Content -LiteralPath $diagnosticsPath -Value $text
    $wrappedProduct = Get-TouchGpioResult -Root $syntheticRoot
    if ($wrappedProduct.verdict -ne 'hardware-chain-proven-awaiting-user-confirmation' -or
        $wrappedProduct.steps['touch-code-0'].status -ne 'proven') {
        throw 'A wrapped product id was not read as the panel identity'
    }
    $packagePath = Join-Path $syntheticRoot 'runtime\package.json'
    $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
    $package.ssdt_sha256 = '0' * 64
    $package | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $packagePath
    $foreign = Get-TouchGpioResult -Root $syntheticRoot
    if ($foreign.verdict -ne 'incomplete' -or $foreign.steps['trial-ssdt-visible-to-windows'].status -ne 'failed') {
        throw 'A foreign SSDT was accepted'
    }
    # A run that wrote neither a completion nor an error receipt was
    # terminated. That is proven failure evidence, not a missing step, and it
    # must never be reported as a finished trial.
    New-SyntheticEvidence $syntheticRoot $true
    Remove-TouchGpioTestItem -LiteralPath (Join-Path $syntheticRoot 'runtime\complete.json') -Force
    $terminated = Get-TouchGpioResult -Root $syntheticRoot
    if ($terminated.steps['runtime-completed'].status -ne 'failed') {
        throw 'A terminated run was not reported as a failure'
    }
    if ($terminated.verdict -ne 'incomplete') {throw "A terminated run was accepted: $($terminated.verdict)"}
    # A clock that moves while the trial task runs is the failure that killed a
    # real attempt. It must be reported from the clock receipt.
    [ordered]@{before_utc='2026-10-21T00:00:00Z';after_utc='2026-10-21T03:28:49Z';host_utc='2026-10-21T03:28:49Z'} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $syntheticRoot 'runtime\clock.json')
    $jumped = Get-TouchGpioResult -Root $syntheticRoot
    if ($jumped.steps['runtime-clock-stable'].status -ne 'failed') {throw 'A clock jump under the task was not reported'}
    if ($jumped.verdict -ne 'incomplete') {throw "A clock jump was accepted: $($jumped.verdict)"}
    # A run that finished with a recorded error is reported as an error, and a
    # stable clock with a completion receipt is reported as a finished run.
    New-SyntheticEvidence $syntheticRoot $true
    [ordered]@{error='PnPUtil install-Touch returned 3010';need_next_boot=$true;utc='2026-10-21T00:00:00Z'} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $syntheticRoot 'runtime\trial-error.json')
    Remove-TouchGpioTestItem -LiteralPath (Join-Path $syntheticRoot 'runtime\complete.json') -Force
    $errored = Get-TouchGpioResult -Root $syntheticRoot
    if ($errored.steps['runtime-no-error'].status -ne 'failed' -or $errored.steps['runtime-completed'].status -ne 'failed') {
        throw 'A run that stopped with an error was not reported'
    }
    Remove-TouchGpioTestItem -LiteralPath (Join-Path $syntheticRoot 'runtime\trial-error.json') -Force
    $bare = Join-Path ([IO.Path]::GetTempPath()) ('timelm-gpio-empty-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $null = [IO.Directory]::CreateDirectory($bare)
    $none = Get-TouchGpioResult -Root $bare
    if ($none.verdict -ne 'no-evidence') {throw "Missing runtime log was not reported: $($none.verdict)"}
    Remove-TouchGpioTestItem -LiteralPath $bare -Recurse -Force
} finally {
    if (Test-Path -LiteralPath $syntheticRoot) {Remove-TouchGpioTestItem -LiteralPath $syntheticRoot -Recurse -Force}
}
'PASS: all GPIO trial scripts parse, the runtime runner rejects this PC before clock, certificate, registry, installation or shutdown operations, the bundle builder only produces a verifiable package, and the result analyzer rejects a wrong identity, a foreign SSDT and missing evidence.'
