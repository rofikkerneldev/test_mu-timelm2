# Safe parser/machine-guard checks on the build PC. Does not stage or install.
param([string]$Artifact)
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {throw 'Run this check on the x64 PC'}
foreach ($file in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors) {throw ($errors | Out-String)}
}
foreach ($runner in @('Launch-TouchGpioTrial.ps1','Run-TouchGpioTrial.ps1','TouchGpioDeviceManager.ps1')) {
    $rejected = $false
    try {& (Join-Path $PSScriptRoot $runner)}
    catch {if ($_.Exception.Message -ne 'Wrong machine') {throw}; $rejected = $true}
    if (!$rejected) {throw "Runner did not reject the PC: $runner"}
}
# Exercise the actual gate writer against in-memory cmdlets only. Recreating an
# existing Device Parameters key could remove other values, so forbid it here.
$runnerPath = Join-Path $PSScriptRoot 'Run-TouchGpioTrial.ps1'
$tokens = $null; $errors = $null
$runnerAst = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath,[ref]$tokens,[ref]$errors)
$writers = @($runnerAst.FindAll({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-Gate'
},$true))
if ($writers.Count -ne 1) {throw 'Expected one production gate writer'}
# The gate reader must survive a property that was never written. Windows
# PowerShell 5.1 throws from Get-ItemPropertyValue in that case, and the
# trial aborted on the phone before it reached any hardware operation.
$readers = @($runnerAst.FindAll({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Get-Gate','Get-RegistryValue')
},$true))
if ($readers.Count -lt 1) {throw 'Expected a production gate reader'}
foreach ($reader in $readers) {
    & {
        param([string]$Definition,[string]$Name)
        $state = @{exists=$true;values=@{NativeGpioI2cEnabled=0;TouchBusGpioEnabled=1}}
        function Test-Path {param([string]$LiteralPath) return $state.exists}
        function Get-ItemProperty {
            param([string]$LiteralPath,[string]$ErrorAction)
            if (!$state.exists) {return $null}
            return [pscustomobject]$state.values
        }
        Invoke-Expression $Definition
        $missing = & $Name 'HKLM:\InMemoryOnly' 'ReadOnlyHardwareProbeEnabled'
        if ($null -ne $missing) {throw "A gate that was never written must read as not enabled: $Name"}
        $zero = & $Name 'HKLM:\InMemoryOnly' 'NativeGpioI2cEnabled'
        if ($null -eq $zero -or $zero -ne 0) {throw "A zero gate must read as zero: $Name"}
        $state.exists = $false
        $absent = & $Name 'HKLM:\InMemoryOnly' 'TouchBusGpioEnabled'
        if ($null -ne $absent) {throw "A missing device key must read as not enabled: $Name"}
    } $reader.Extent.Text $reader.Name
}
& {
    param([string]$Definition)
    $state = @{exists=$true;created=0;values=@{ExistingProviderValue=17};badReadback=$false}
    function Test-Path {param([string]$LiteralPath) return $state.exists}
    function New-Item {
        param([string]$Path,[switch]$Force)
        if ($state.exists -or $Force) {throw 'Existing device key must not be recreated'}
        $state.exists = $true; $state.created++
    }
    function New-ItemProperty {
        param([string]$LiteralPath,[string]$Name,[int]$Value,[string]$PropertyType,[switch]$Force)
        if (!$state.exists -or $PropertyType -ne 'DWord' -or !$Force) {throw 'Invalid gate write'}
        $state.values[$Name] = $Value
    }
    function Get-ItemPropertyValue {
        param([string]$LiteralPath,[string]$Name)
        if ($state.badReadback) {return -1}
        return $state.values[$Name]
    }
    Invoke-Expression $Definition
    Set-Gate 'HKLM:\InMemoryOnly' 'FirstGate' 0
    Set-Gate 'HKLM:\InMemoryOnly' 'SecondGate' 1
    if ($state.created -ne 0 -or $state.values.ExistingProviderValue -ne 17 -or
        $state.values.FirstGate -ne 0 -or $state.values.SecondGate -ne 1) {throw 'Gate writer replaced other device parameters'}
    $state.exists = $false
    Set-Gate 'HKLM:\InMemoryOnly' 'ThirdGate' 1
    if ($state.created -ne 1) {throw 'Missing device key was not created once'}
    $state.badReadback = $true; $rejected = $false
    try {Set-Gate 'HKLM:\InMemoryOnly' 'FailedGate' 1}
    catch {if ($_.Exception.Message -ne 'Gate readback failed: FailedGate') {throw};$rejected = $true}
    if (!$rejected) {throw 'Gate readback failure was ignored'}
} $writers[0].Extent.Text
$launch = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Launch-TouchGpioTrial.ps1') -Raw
if ($launch -notmatch 'New-TimeSpan\s+-Minutes\s+120\b' -or $launch -notmatch 'execution_limit_minutes=120\b') {throw 'Task timeout and receipt must cover the bounded trial'}
# The phone clock is corrected before the scheduled task exists. A clock jump
# while a task with an execution time limit runs makes Task Scheduler compute
# the task runtime from the new time and hard terminate the action, which
# ended a real attempt before any hardware step.
$runnerText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Run-TouchGpioTrial.ps1') -Raw
if ($runnerText -match 'Set-Date') {throw 'The runtime runner must never change the clock under the task'}
if ($launch -notmatch 'Set-Date') {throw 'The launcher must correct the phone clock before the task starts'}
$clockIndex = $launch.IndexOf('Set-Date')
$registerIndex = $launch.IndexOf('Register-ScheduledTask')
if ($clockIndex -lt 0 -or $registerIndex -lt 0 -or $clockIndex -gt $registerIndex) {throw 'The clock must be corrected before the scheduled task is registered'}
if ($runnerText -notmatch 'Assert-Budget' -or $runnerText -notmatch 'Stopwatch') {throw 'The runtime runner must bound the trial with a monotonic budget'}
# PnPUtil answers 259 (ERROR_NO_MORE_ITEMS) when the package is already the
# selected driver for that device. That is a successful install, and treating
# it as a failure aborted a real attempt before any hardware step. The exit
# code is still recorded and the selected INF is verified separately.
if ($runnerText -notmatch '\$code -eq 0 -or \$code -eq 259') {throw 'The runtime runner must tolerate the PnPUtil no-more-items exit code'}
if ($runnerText -notmatch 'ERROR_NO_MORE_ITEMS') {throw 'The tolerated exit code must be documented in the runner'}
if ($runnerText -notmatch 'phase-host-started\.json' -or $runnerText -notmatch 'phase-test-window\.json') {
    throw 'The runtime runner must publish phase receipts for the desktop session'
}
# The enumeration timeline has to be recorded as plain text around every
# provider restart, because the ACPI child of the bus host may only exist for
# a moment. A live trace of the kernel PnP and ACPI providers is the second
# half of that evidence.
if ($runnerText -notmatch 'Watch-DeviceNodes\.ps1' -or $runnerText -notmatch 'watch-' -or
    $runnerText -notmatch 'Copy-SetupApiLog') {
    throw 'The runtime runner must record the enumeration timeline and the SetupAPI snapshots'
}
if ($runnerText -notmatch 'Start-LiveTrace' -or $runnerText -notmatch 'Microsoft-Windows-Kernel-Acpi') {
    throw 'The runtime runner must record a live trace of the kernel PnP and ACPI providers'
}
$watcher = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Watch-DeviceNodes.ps1') -Raw
if ($watcher -notmatch 'ConvertTo-Json' -or $watcher -notmatch 'Add-Content') {
    throw 'The device node sampler must write plain text samples'
}
# The sampler is started by the runner as a separate process, so its machine
# guard has to be checked on its own: its parameter is mandatory and the guard
# is only reached once the parameter is bound.
$watcherRejected = $false
try {& (Join-Path $PSScriptRoot 'Watch-DeviceNodes.ps1') -Output (Join-Path $env:TEMP 'timelm-guard-watch.jsonl')}
catch {if ($_.Exception.Message -ne 'Wrong machine') {throw}; $watcherRejected = $true}
if (!$watcherRejected) {throw 'The device node sampler did not reject the PC'}
# A gate that an earlier attempt of this bundle left enabled is restored, and
# a gate that anybody else enabled is refused instead of reset.
if ($runnerText -notmatch 'Pre-existing hardware gate enabled' -or $runnerText -notmatch 'gates-restored\.json') {
    throw 'The runtime runner must restore only its own gates and record the restore'
}
# A re-arm on the phone may only remove the Startup entry that this script
# staged itself. Anything else has to stay untouched.
$stage = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Stage-TouchGpioTrial.ps1') -Raw
if ($stage -notmatch 'refusing to disarm it' -or $stage -notmatch 'refusing to rearm') {
    throw 'The staging re-arm must refuse a foreign Startup entry and a plain re-arm'
}
# A clean bundle is staged with the host gate written as zero. One is only
# staged when this bundle's own host INF is already installed: the resumed
# attempt's first device start has to reach the bitbang prepare path.
if ($stage -notmatch 'resumeFromInstalledInf' -or $stage -notmatch '-GateValue \$gateTarget') {
    throw 'The staging must reserve the armed host gate for a resumed attempt'
}
# Retiring a previous attempt is still a re-arm: the old bundle must prove the
# trial family identity (manifest rules plus restore-first metadata for the)
# same Windows image) before its leftovers are archived.
if ($stage -notmatch 'GPIO trial family' -or $stage -notmatch 'touch-gpio\.json') {
    throw 'The staging must retire only provably own previous attempt leftovers'
}
# The Device Manager helper opens the console in the desktop session and has to
# expand it, so the drivers Windows loaded are visible while the trial runs.
$helper = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'TouchGpioDeviceManager.ps1') -Raw
if ($helper -notmatch 'ExpandCollapsePattern' -or $helper -notmatch 'devmgmt\.msc') {
    throw 'The Device Manager helper must open and expand the console'
}
if ($helper -notmatch 'Send-Keys ''\*''' -or $helper -notmatch 'uia') {
    throw 'The Device Manager helper must keep a keyboard fallback for the tree'
}
$helperCmd = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Timelm-device-manager.cmd') -Raw
if ($helperCmd -notmatch 'TouchGpioDeviceManager\.ps1' -or $helperCmd -notmatch 'ARM64' -or $helperCmd -notmatch 'TIMELM-V60') {
    throw 'The Device Manager startup entry must be guarded and must call the helper'
}
if ($stage -notmatch 'Timelm-device-manager\.cmd' -or
    $stage -notmatch 'Device manager startup entry is not this trial own') {
    throw 'The staging must arm the Device Manager helper and refuse a foreign entry'
}
# The button trial entry keeps the Volume, Power and Assist keys usable while
# the touch trial is on the screen, and it is disarmed by the same rule.
if ($stage -notmatch 'Timelm-buttons\.cmd' -or
    $stage -notmatch 'Button startup entry is not this trial own') {
    throw 'The staging must arm the button trial entry and refuse a foreign entry'
}
# The helper watches the state the driver published and writes it to a file
# that survives a bugcheck of the kernel.
if ($helper -notmatch 'driver-status\.log' -or $helper -notmatch 'TimelmBitbangStage') {
    throw 'The Device Manager helper must record the live driver status'
}
# The driver writes the steps of the bitbang path to a file and flushes every
# line, because the registry is lost when the kernel bugchecks.
$driverRoot = Join-Path $PSScriptRoot '..\..\..\GPLDrivers\Windows\KonaGeniI2c'
$traceSource = Get-Content -LiteralPath (Join-Path $driverRoot 'trace_windows.c') -Raw
$bitbangSource = Get-Content -LiteralPath (Join-Path $driverRoot 'bitbang_windows.c') -Raw
$driverSource = Get-Content -LiteralPath (Join-Path $driverRoot 'driver.c') -Raw
if ($traceSource -notmatch 'ZwFlushBuffersFile' -or $traceSource -notmatch 'driver-trace\.log') {
    throw 'The driver trace must flush every line to the disk'
}
if ($bitbangSource -notmatch 'TimelmTrace' -or $driverSource -notmatch 'TimelmTrace') {
    throw 'The bitbang path must write its trace'
}
if ((Get-Content -LiteralPath (Join-Path $driverRoot 'kona_geni.vcxproj') -Raw) -notmatch 'trace_windows\.c') {
    throw 'The driver project must build the trace'
}
if ($Artifact) {
    . (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
    $null = Get-TouchGpioManifest $Artifact
}
& (Join-Path $PSScriptRoot 'Test-TouchGpioPackage.ps1')
# Exercise the result analyzer on a synthetic evidence tree. No phone and no
# hardware: a wrong chip identity, a foreign SSDT or a missing runtime log
# must never be reported as an accepted trial.
. (Join-Path $PSScriptRoot 'Analyze-TouchGpioResult.ps1')
function Get-SyntheticHash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')} finally {$sha.Dispose()}
    } finally {$stream.Dispose()}
}
function New-SyntheticEvidence([string]$Root, [bool]$Good, [int]$FirstPinId = 38) {
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
        [ordered]@{device='TIML0001';name='TimelmBitbangPinId1';value=67},
        [ordered]@{device='TIML0001';name='TimelmBitbangPinId2';value=68},
        [ordered]@{device='TIML0001';name='TimelmBitbangPinId3';value=36},
        [ordered]@{device='TIML0001';name='TimelmBitbangPinId4';value=37},
        [ordered]@{device='TIML0001';name='TimelmBitbangIdleLines';value=3},
        [ordered]@{device='TIML0001';name='TimelmBitbangIdentityStatus';value=0},
        [ordered]@{device='TIML0001';name='TimelmBitbangIdentity0';value=$identity0},
        [ordered]@{device='TIML0001';name='TimelmBitbangIdentity1';value=$identity1},
        [ordered]@{device='TIML0001';name='TimelmBitbangStatus';value=0},
        [ordered]@{device='LGSW4290';name='TimelmTouchStartStatus';value=0},
        [ordered]@{device='LGSW4290';name='TimelmTouchProductId';value=@($expected)},
        [ordered]@{device='LGSW4290';name='TimelmTouchIrqs';value=7},
        [ordered]@{device='LGSW4290';name='TimelmTouchDecoded';value=5})
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
    Remove-Item -LiteralPath (Join-Path $syntheticRoot 'runtime\after') -Recurse -Force
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
    New-SyntheticEvidence $syntheticRoot $true 39
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
    Remove-Item -LiteralPath (Join-Path $syntheticRoot 'runtime\complete.json') -Force
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
    Remove-Item -LiteralPath (Join-Path $syntheticRoot 'runtime\complete.json') -Force
    $errored = Get-TouchGpioResult -Root $syntheticRoot
    if ($errored.steps['runtime-no-error'].status -ne 'failed' -or $errored.steps['runtime-completed'].status -ne 'failed') {
        throw 'A run that stopped with an error was not reported'
    }
    Remove-Item -LiteralPath (Join-Path $syntheticRoot 'runtime\trial-error.json') -Force
    $bare = Join-Path ([IO.Path]::GetTempPath()) ('timelm-gpio-empty-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $null = [IO.Directory]::CreateDirectory($bare)
    $none = Get-TouchGpioResult -Root $bare
    if ($none.verdict -ne 'no-evidence') {throw "Missing runtime log was not reported: $($none.verdict)"}
    Remove-Item -LiteralPath $bare -Recurse -Force
} finally {
    if (Test-Path -LiteralPath $syntheticRoot) {Remove-Item -LiteralPath $syntheticRoot -Recurse -Force}
}
'PASS: all GPIO trial scripts parse, the runtime runner rejects this PC before clock, certificate, registry, installation or shutdown operations, the bundle builder only produces a verifiable package, and the result analyzer rejects a wrong identity, a foreign SSDT and missing evidence.'
