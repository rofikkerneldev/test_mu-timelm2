# SPDX-License-Identifier: BSD-2-Clause-Patent
# Pure analysis of a copied GPIO touch trial evidence tree. No phone, no
# hardware and no registry access: this file only reads JSON and text files
# that were already collected from the phone.
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
function Get-TouchGpioLogValue {
    param([string[]]$Lines, [string]$Marker)
    # The launcher appends one checkpoint block per save, so the last
    # occurrence of a marker is the authoritative one for that boot.
    $value = $null
    foreach ($line in $Lines) {
        $index = $line.IndexOf($Marker, [StringComparison]::Ordinal)
        if ($index -lt 0) {continue}
        $match = [regex]::Match($line.Substring($index + $Marker.Length), '0x[0-9a-fA-F]{16}')
        if ($match.Success) {$value = $match.Value}
    }
    return $value
}
function Read-TouchGpioJson {
    param([string]$Path)
    if (!(Test-Path -LiteralPath $Path)) {return $null}
    try {
        $text=Get-Content -LiteralPath $Path -Raw
        if([string]::IsNullOrWhiteSpace($text) -or $text.IndexOf([char]0) -ge 0){return $null}
        return $text | ConvertFrom-Json -ErrorAction Stop
    } catch {return $null}
}
function ConvertTo-TouchGpioItems {
    param($Value)
    # Windows PowerShell 5.1 can serialize a JSON array as {"value":[...],
    # "Count":N}. Accept both shapes so a phone written collection is never
    # misread as an empty result. The wrapper is only unwrapped when the
    # object carries that exact pair of properties, because a single
    # diagnostic entry also has a "value" property of its own.
    if ($null -eq $Value) {return @()}
    $items = @($Value)
    if ($items.Count -eq 1) {
        $single = $items[0]
        if ($single -isnot [string] -and $single -isnot [ValueType] -and
            $single.PSObject.Properties['value'] -and $single.PSObject.Properties['Count']) {
            $inner = @($single.value)
            if ($inner.Count -gt 0) {return $inner}
        }
    }
    return $items
}
function Get-TouchGpioValue {
    param([object[]]$Diagnostics, [string]$Device, [string]$Name)
    if ($null -eq $Diagnostics) {return $null}
    $match = @($Diagnostics | Where-Object {$_.device -ieq $Device -and $_.name -ieq $Name})
    if ($match.Count -ne 1) {return $null}
    return $match[0].value
}
function ConvertTo-TouchGpioBytes {
    param($Value)
    if ($null -eq $Value) {return $null}
    if ($Value -is [byte[]]) {return ,$Value}
    if ($Value -is [Array]) {return ,([byte[]]@($Value | ForEach-Object {[byte]$_}))}
    # Windows PowerShell 5.1 can also wrap a nested array as {"value":[...],
    # "Count":N}. A product id that stays unreadable must never look like a
    # matching panel.
    if ($Value -isnot [string] -and $Value -isnot [ValueType] -and
        $Value.PSObject.Properties['value'] -and $Value.PSObject.Properties['Count']) {
        $inner = @($Value.value)
        if ($inner.Count -gt 0) {return ,([byte[]]@($inner | ForEach-Object {[byte]$_}))}
    }
    return $null
}
function ConvertTo-TouchGpioIdentity {
    param($Low, $High)
    if ($null -eq $Low -or $null -eq $High) {return $null}
    try {
        $l = [uint64]$Low; $h = [uint64]$High
    } catch {return $null}
    $bytes = New-Object byte[] 8
    for ($i = 0; $i -lt 4; ++$i) {$bytes[$i] = [byte](($l -shr (8*$i)) -band 0xFF)}
    for ($i = 0; $i -lt 4; ++$i) {$bytes[4+$i] = [byte](($h -shr (8*$i)) -band 0xFF)}
    return [Text.Encoding]::ASCII.GetString($bytes)
}
function ConvertTo-TouchGpioTime($Value) {
    # Windows PowerShell 5.1 keeps a JSON date as a string, while newer
    # PowerShell converts it to a DateTime during parsing. Both shapes have to
    # give the same instant, and a value that cannot be read must never look
    # like a stable clock.
    if ($null -eq $Value) {return $null}
    if ($Value -is [DateTime]) {return $Value.ToUniversalTime()}
    if ($Value -is [DateTimeOffset]) {return $Value.UtcDateTime}
    try {
        return [DateTime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    } catch {return $null}
}
function Add-TouchGpioStep {
    param([System.Collections.Specialized.OrderedDictionary]$Steps, [string]$Name,
          [string]$Status, [string]$Detail)
    $Steps[$Name] = [ordered]@{status=$Status;detail=$Detail}
}
function Get-TouchGpioResult {
    param([Parameter(Mandatory=$true)][string]$Root, [bool]$TapSwipeObserved = $false)
    $result = [ordered]@{
        root = $Root
        utc = [DateTime]::UtcNow.ToString('o')
        verdict = 'no-evidence'
        tap_swipe = 'user-confirmation-required'
        steps = [ordered]@{}
        facts = [ordered]@{}
    }
    $steps = $result.steps
    $facts = $result.facts
    $runtime = Join-Path $Root 'runtime'
    if (!(Test-Path -LiteralPath (Join-Path $runtime 'attempt.json'))) {
        Add-TouchGpioStep $steps 'runtime-attempt' 'missing' 'no attempt.json: the SYSTEM task never started on the phone'
        return $result
    }
    Add-TouchGpioStep $steps 'runtime-attempt' 'proven' 'the SYSTEM task started and created the attempt receipt'
    $invalid=@()
    foreach($file in @(Get-ChildItem -LiteralPath $runtime -Filter '*.json' -File)) {
        try {
            $text=Get-Content -LiteralPath $file.FullName -Raw
            if([string]::IsNullOrWhiteSpace($text) -or $text.IndexOf([char]0) -ge 0){throw 'Empty or NUL receipt'}
            $null=$text | ConvertFrom-Json -ErrorAction Stop
        }
        catch {$invalid+=$file.Name}
    }
    Add-TouchGpioStep $steps 'valid-runtime-receipts' $(if($invalid.Count){'failed'}else{'proven'}) ('invalid JSON: '+($invalid -join ','))
    $bootLog = Join-Path $Root 'boot\timelm-touch-gpio.txt'
    if (Test-Path -LiteralPath $bootLog) {
        $lines = @(Get-Content -LiteralPath $bootLog)
        $facts['boot_log_lines'] = $lines.Count
        $restore = Get-TouchGpioLogValue $lines 'Restore status='
        $gate = Get-TouchGpioLogValue $lines 'Enumeration namespace gate='
        $install = Get-TouchGpioLogValue $lines 'Install enumeration SSDT='
        $readback = Get-TouchGpioLogValue $lines 'Enumeration table readback='
        $facts['boot_restore_status'] = $restore
        $facts['boot_namespace_gate'] = $gate
        $facts['boot_ssdt_install'] = $install
        $facts['boot_ssdt_readback'] = $readback
        $chainload = @($lines | Where-Object {$_ -like '*BEFORE StartImage (original Windows Boot Manager)*'}).Count -gt 0
        $facts['boot_chainload_windows'] = $chainload
        Add-TouchGpioStep $steps 'boot-restore-windows' $(if ($restore -eq '0x0000000000000000') {'proven'} else {'failed'}) `
            ("last restore status " + $(if ($null -eq $restore) {'absent'} else {$restore}))
        Add-TouchGpioStep $steps 'boot-namespace-gate' $(if ($gate -eq '0x0000000000000000') {'proven'} else {'failed'}) `
            ("last namespace gate " + $(if ($null -eq $gate) {'absent'} else {$gate}))
        Add-TouchGpioStep $steps 'boot-ssdt-installed' $(if ($install -eq '0x0000000000000000') {'proven'} else {'failed'}) `
            ("last SSDT install " + $(if ($null -eq $install) {'absent'} else {$install}))
        Add-TouchGpioStep $steps 'boot-ssdt-readback' $(if ($readback -eq '0x0000000000000000') {'proven'} else {'failed'}) `
            ("last SSDT readback " + $(if ($null -eq $readback) {'absent'} else {$readback}))
        Add-TouchGpioStep $steps 'boot-chainload-windows' $(if ($chainload) {'proven'} else {'missing'}) `
            'the launcher handed the original Windows boot manager the kernel'
    } else {
        Add-TouchGpioStep $steps 'boot-restore-windows' 'missing' 'the EFI launcher log was not collected'
    }
    $package = Read-TouchGpioJson (Join-Path $runtime 'package.json')
    $expectedSsdt = $null
    if ($package -and $package.ssdt_sha256 -match '^[0-9a-fA-F]{64}$') {$expectedSsdt = $package.ssdt_sha256.ToUpperInvariant()}
    $facts['expected_ssdt_sha256'] = $expectedSsdt
    $before = @(Get-ChildItem -LiteralPath (Join-Path $runtime 'before') -Directory -ErrorAction SilentlyContinue)
    $beforeFolder = if ($before.Count -eq 1) {$before[0].FullName} else {$null}
    if ($beforeFolder) {
        $ssdtFile = Join-Path $beforeFolder 'SSDT.dat'
        if (Test-Path -LiteralPath $ssdtFile) {
            $hash = (Get-FileHash -LiteralPath $ssdtFile).Hash.ToUpperInvariant()
            $facts['observed_ssdt_sha256'] = $hash
            Add-TouchGpioStep $steps 'trial-ssdt-visible-to-windows' `
                $(if ($expectedSsdt -and $hash -eq $expectedSsdt) {'proven'} else {'failed'}) `
                ("Windows first SSDT " + $hash + " expected " + $(if ($expectedSsdt) {$expectedSsdt} else {'unknown'}))
        } else {
            Add-TouchGpioStep $steps 'trial-ssdt-visible-to-windows' 'missing' 'the baseline collection has no SSDT.dat'
        }
        $tables = Read-TouchGpioJson (Join-Path $beforeFolder 'acpi-table-list.json')
        if ($tables) {
            $ssdtCount = @($tables.tables | Where-Object {$_.signature -eq 'SSDT'}).Count
            $iortCount = @($tables.tables | Where-Object {$_.signature -eq 'IORT'}).Count
            $facts['ssdt_table_count'] = $ssdtCount
            $facts['iort_table_count'] = $iortCount
            Add-TouchGpioStep $steps 'no-iort-installed' $(if ($iortCount -eq 0) {'proven'} else {'failed'}) `
                ("IORT tables in the baseline: " + $iortCount)
        } else {
            Add-TouchGpioStep $steps 'no-iort-installed' 'missing' 'no acpi-table-list.json in the baseline collection'
        }
    } else {
        Add-TouchGpioStep $steps 'trial-ssdt-visible-to-windows' 'missing' 'no baseline collection folder'
        Add-TouchGpioStep $steps 'no-iort-installed' 'missing' 'no baseline collection folder'
    }
    $error = Read-TouchGpioJson (Join-Path $runtime 'trial-error.json')
    if ($error) {
        $facts['trial_error'] = $error.error
        Add-TouchGpioStep $steps 'runtime-no-error' 'failed' ([string]$error.error)
    } else {
        Add-TouchGpioStep $steps 'runtime-no-error' 'proven' 'no trial-error.json was written'
    }
    # A missing error receipt is not a finished run. The completion receipt is
    # only written after the final collection, so its absence proves that the
    # action ended before the trial was over.
    $complete = Read-TouchGpioJson (Join-Path $runtime 'complete.json')
    if ($complete) {
        Add-TouchGpioStep $steps 'runtime-completed' 'proven' 'the runner wrote the completion receipt'
    } elseif ($error) {
        Add-TouchGpioStep $steps 'runtime-completed' 'failed' 'the runner stopped with a recorded error and never wrote the completion receipt'
    } else {
        Add-TouchGpioStep $steps 'runtime-completed' 'failed' 'no completion or error receipt: evidence is incomplete; termination cause is unknown'
    }
    # The phone clock must not move while the trial task runs. A clock jump
    # inside a task with an execution time limit makes Task Scheduler compute
    # the task runtime from the new time and hard terminate the action, which
    # ended a previous attempt before any hardware step.
    $clock = Read-TouchGpioJson (Join-Path $runtime 'clock.json')
    if ($clock -and $clock.before_utc -and $clock.after_utc) {
        $clockBefore = ConvertTo-TouchGpioTime $clock.before_utc
        $clockAfter = ConvertTo-TouchGpioTime $clock.after_utc
        if ($null -eq $clockBefore -or $null -eq $clockAfter) {
            Add-TouchGpioStep $steps 'runtime-clock-stable' 'failed' 'the clock receipt could not be read'
        } else {
            $jump = ($clockAfter - $clockBefore).TotalSeconds
            $facts['runtime_clock_jump_seconds'] = $jump
            Add-TouchGpioStep $steps 'runtime-clock-stable' $(if ([Math]::Abs($jump) -le 60) {'proven'} else {'failed'}) `
                ("the phone clock moved " + [Math]::Round($jump,1) + " seconds while the trial task ran")
        }
    } else {
        Add-TouchGpioStep $steps 'runtime-clock-stable' 'missing' 'no clock.json in the runtime log'
    }
    $operations = Read-TouchGpioJson (Join-Path $runtime 'operations.json')
    if ($operations) {
        $bad = @($operations | Where-Object {$_.operation -like 'install-*' -and $_.exit_code -notin @(0,259)})
        $facts['pnp_operations'] = @($operations).Count
        Add-TouchGpioStep $steps 'pnp-installs' $(if ($bad.Count -eq 0) {'proven'} else {'failed'}) `
            ("install operations with a non-zero exit code: " + $bad.Count)
    } else {
        Add-TouchGpioStep $steps 'pnp-installs' 'missing' 'no operations.json'
    }
    foreach ($packageName in @('GPIO','Host','Touch')) {
        $selected = Read-TouchGpioJson (Join-Path $runtime ('selected-' + $packageName + '-inf.json'))
        if ($null -eq $selected) {
            # No receipt means the device was never offered the package, so
            # this is missing evidence rather than a proven mismatch.
            Add-TouchGpioStep $steps ('selected-inf-' + $packageName.ToLowerInvariant()) 'missing' `
                'the trial never recorded a driver selection for this package'
        } elseif ($selected.matches -eq $true) {
            Add-TouchGpioStep $steps ('selected-inf-' + $packageName.ToLowerInvariant()) 'proven' `
                ([string]$selected.inf + ' matches the staged package hash')
        } else {
            Add-TouchGpioStep $steps ('selected-inf-' + $packageName.ToLowerInvariant()) 'failed' `
                'the device did not select the staged driver package'
        }
    }
    $after = @(Get-ChildItem -LiteralPath (Join-Path $runtime 'after') -Directory -ErrorAction SilentlyContinue)
    $afterFolder = if ($after.Count -eq 1) {$after[0].FullName} else {$null}
    $diagnostics = $null
    $entities = $null
    if ($afterFolder) {
        $diagnostics = ConvertTo-TouchGpioItems (Read-TouchGpioJson (Join-Path $afterFolder 'touch-driver-diagnostics.json'))
        $entities = ConvertTo-TouchGpioItems (Read-TouchGpioJson (Join-Path $afterFolder 'pnp-entities.json'))
    }
    $stage = Get-TouchGpioValue $diagnostics 'TIML0001' 'TimelmBitbangStage'
    $facts['host_bitbang_stage'] = $stage
    Add-TouchGpioStep $steps 'gpio-provider-v3' $(if ($null -ne $stage -and [uint64]$stage -ge 2) {'proven'} else {'missing'}) `
        ("host GPIO stage " + $(if ($null -eq $stage) {'absent'} else {$stage}) + " (2 means interface query and readiness passed; 3 means GPIO mode enabled)")
    # Connection IDs are opaque 64-bit Resource Hub identifiers. Physical
    # pin roles come from the pinned SSDT and provider, never from IdLowPart.
    $pinCount=Get-TouchGpioValue $diagnostics 'TIML0001' 'TimelmBitbangPinCount'
    $facts['host_bitbang_pin_count']=$pinCount
    $pinIds=@();$shapeStatus='missing';$shapeDetail='connection resources absent'
    if($null -ne $pinCount -and $pinCount -in @(4,5)) {
        $shapeStatus='proven';$ordinals=@();$identities=@{}
        for($i=0;$i -lt [int]$pinCount;++$i) {
            $low=Get-TouchGpioValue $diagnostics 'TIML0001' ('TimelmBitbangPinId'+$i)
            $high=Get-TouchGpioValue $diagnostics 'TIML0001' ('TimelmBitbangPinIdHigh'+$i)
            $ordinal=Get-TouchGpioValue $diagnostics 'TIML0001' ('TimelmBitbangConnOrdinal'+$i)
            if($null -eq $low -or $null -eq $high -or $null -eq $ordinal) {$shapeStatus='missing';continue}
            $id=([string]$high)+':'+([string]$low)
            if(($low -eq 0 -and $high -eq 0) -or $identities.ContainsKey($id) -or
                $ordinal -le 0 -or ($ordinals.Count -and $ordinal -le $ordinals[-1])) {$shapeStatus='failed'}
            $identities[$id]=$true;$pinIds+=$id;$ordinals+=$ordinal
        }
        $shapeDetail='opaque IDs '+($pinIds -join ',')+'; ordered connection roles checked against pinned SSDT by the adapter'
    } elseif($null -ne $pinCount) {$shapeStatus='failed';$shapeDetail='unexpected GPIO connection count'}
    $facts['host_bitbang_pin_ids']=$pinIds
    Add-TouchGpioStep $steps 'gpio-resource-shape' $shapeStatus $shapeDetail
    $epoch=Read-TouchGpioJson (Join-Path $runtime 'driver-attempt.json')
    $fresh='missing';$detail='no attempt/generation binding'
    if($epoch -and $epoch.mode -eq 'test') {
        $parameters=@{}
        foreach($d in @($diagnostics | Where-Object {$_.device -ieq 'TIML0001'})) {$parameters[$d.name]=$d.value}
        try {Assert-TouchGpioHostEvidence ([pscustomobject]$parameters) ([uint32]$epoch.attempt_id) ([uint32]$epoch.expected_build_id);$fresh='proven';$detail='exact attempt/build/backend and completed live provider epoch'}
        catch {$fresh='failed';$detail=$_.Exception.Message}
    }
    Add-TouchGpioStep $steps 'fresh-host-evidence' $fresh $detail
    $provider=Read-TouchGpioJson (Join-Path $runtime 'provider-gates-after-restart.json')
    $ready='missing'
    if($provider) {try {Assert-TouchGpioProviderGate $provider.TouchBusGpioEnabled $provider.TimelmGpioBitbangGate;$ready='proven'}catch{$ready='failed'}}
    Add-TouchGpioStep $steps 'provider-gate' $ready 'requested/effective gate must both equal 1; host also queries live V4 state'
    foreach ($counter in @('TimelmBitbangTransfers', 'TimelmBitbangFailures', 'TimelmBitbangLastStatus',
                            'TimelmBitbangRetained', 'TimelmBitbangStopStatus')) {
        $value = Get-TouchGpioValue $diagnostics 'TIML0001' $counter
        if ($null -ne $value) { $facts['host_' + $counter.Substring('TimelmBitbang'.Length).ToLowerInvariant()] = $value }
    }
    $idle = Get-TouchGpioValue $diagnostics 'TIML0001' 'TimelmBitbangIdleLines'
    $facts['host_idle_lines'] = $idle
    Add-TouchGpioStep $steps 'idle-lines-high' $(if ($null -ne $idle -and [uint64]$idle -eq 3) {'proven'} else {'missing'}) `
        ("idle line sample " + $(if ($null -eq $idle) {'absent'} else {$idle}) + " (3 means SCL and SDA are high)")
    $identityStatus = Get-TouchGpioValue $diagnostics 'TIML0001' 'TimelmBitbangIdentityStatus'
    $identity = ConvertTo-TouchGpioIdentity `
        (Get-TouchGpioValue $diagnostics 'TIML0001' 'TimelmBitbangIdentity0') `
        (Get-TouchGpioValue $diagnostics 'TIML0001' 'TimelmBitbangIdentity1')
    $facts['host_identity_status'] = $identityStatus
    $facts['host_identity'] = $identity
    Add-TouchGpioStep $steps 'chip-identity' `
        $(if ($null -ne $identityStatus -and [uint64]$identityStatus -eq 0 -and $identity -ceq 'B3W68TIM') {'proven'} else {'missing'}) `
        ("identity " + $(if ($null -eq $identity) {'absent'} else {$identity}) + " status " + $(if ($null -eq $identityStatus) {'absent'} else {$identityStatus}))
    $hostStatus = Get-TouchGpioValue $diagnostics 'TIML0001' 'TimelmBitbangStatus'
    $facts['host_status'] = $hostStatus
    $hostEntity = @($entities | Where-Object {$_.PNPDeviceID -like 'ACPI\TIML0001\*'})
    $hostError = if ($hostEntity.Count -eq 1) {$hostEntity[0].ConfigManagerErrorCode} else {$null}
    $facts['host_config_manager_error'] = $hostError
    Add-TouchGpioStep $steps 'host-code-0' `
        $(if ($null -ne $hostStatus -and [uint64]$hostStatus -eq 0 -and $null -ne $hostError -and [uint64]$hostError -eq 0) {'proven'} else {'missing'}) `
        ("host status " + $(if ($null -eq $hostStatus) {'absent'} else {$hostStatus}) + " device code " + $(if ($null -eq $hostError) {'absent'} else {$hostError}))
    $touchStatus = Get-TouchGpioValue $diagnostics 'LGSW4290' 'TimelmTouchStartStatus'
    $productBytes = ConvertTo-TouchGpioBytes (Get-TouchGpioValue $diagnostics 'LGSW4290' 'TimelmTouchProductId')
    $product = if ($productBytes) {[Text.Encoding]::ASCII.GetString($productBytes)} else {$null}
    $facts['touch_start_status'] = $touchStatus
    $facts['touch_product_id'] = $product
    $touchEntity = @($entities | Where-Object {$_.PNPDeviceID -like 'ACPI\LGSW4290\*'})
    $touchError = if ($touchEntity.Count -eq 1) {$touchEntity[0].ConfigManagerErrorCode} else {$null}
    $facts['touch_config_manager_error'] = $touchError
    Add-TouchGpioStep $steps 'touch-code-0' `
        $(if ($null -ne $touchStatus -and [uint64]$touchStatus -eq 0 -and $null -ne $touchError -and [uint64]$touchError -eq 0 -and $product -ceq 'B3W68TIM') {'proven'} else {'missing'}) `
        ("touch start " + $(if ($null -eq $touchStatus) {'absent'} else {$touchStatus}) + " product " + $(if ($null -eq $product) {'absent'} else {$product}) + " device code " + $(if ($null -eq $touchError) {'absent'} else {$touchError}))
    $irqs = Get-TouchGpioValue $diagnostics 'LGSW4290' 'TimelmTouchIrqs'
    $decoded = Get-TouchGpioValue $diagnostics 'LGSW4290' 'TimelmTouchDecoded'
    $facts['touch_irqs'] = $irqs
    $facts['touch_decoded_reports'] = $decoded
    Add-TouchGpioStep $steps 'irq-and-reports' `
        $(if ($null -ne $irqs -and [uint64]$irqs -gt 0 -and $null -ne $decoded -and [uint64]$decoded -gt 0) {'proven'} else {'missing'}) `
        ("interrupts " + $(if ($null -eq $irqs) {'absent'} else {$irqs}) + " decoded reports " + $(if ($null -eq $decoded) {'absent'} else {$decoded}))
    $window = Read-TouchGpioJson (Join-Path $runtime 'touch-window.json')
    Add-TouchGpioStep $steps 'test-window' $(if ($window) {'proven'} else {'missing'}) `
        $(if ($window) {('the desktop test window opened at ' + $window.utc)} else {'no touch-window.json: the driver never reached the test window'})
    Add-TouchGpioStep $steps 'tap-and-swipe' $(if ($TapSwipeObserved) {'proven'} else {'missing'}) `
        $(if ($TapSwipeObserved) {'the user reported a real tap and swipe'} else {'no user confirmation was recorded'})
    $ordered = @('runtime-attempt','boot-restore-windows','boot-namespace-gate','boot-ssdt-installed','boot-ssdt-readback',
        'boot-chainload-windows','trial-ssdt-visible-to-windows','no-iort-installed','runtime-no-error','runtime-completed',
        'runtime-clock-stable','pnp-installs','valid-runtime-receipts','fresh-host-evidence','provider-gate',
        'selected-inf-gpio','selected-inf-host','selected-inf-touch','gpio-provider-v3','gpio-resource-shape',
        'idle-lines-high','chip-identity','host-code-0','touch-code-0','irq-and-reports','test-window','tap-and-swipe')
    if($epoch -and $epoch.supervised -eq $true) {
        $supervisor=Read-TouchGpioJson (Join-Path $runtime 'supervisor.json')
        $ok=$supervisor -and $supervisor.attempt_id -eq $epoch.attempt_id -and
            $supervisor.phase -eq 'worker-exited' -and $null -ne $supervisor.worker_exit_code -and
            $supervisor.worker_exit_code -eq 0 -and !$supervisor.worker_error -and
            $supervisor.shutdown_requested -eq $true -and !$supervisor.shutdown_error
        Add-TouchGpioStep $steps 'supervisor-shutdown-request' $(if($ok){'proven'}else{'failed'}) `
            'matching supervisor receipt must show worker exit and an accepted shutdown request; this does not prove physical power-off'
        $ordered+='supervisor-shutdown-request'
    }
    if($epoch -and $epoch.mode -eq 'prepare') {
        $prepared=Read-TouchGpioJson (Join-Path $runtime 'prepared.json')
        $deferred=Read-TouchGpioJson (Join-Path $runtime 'deferred-result.json')
        $gates=Read-TouchGpioJson (Join-Path $runtime 'gates-before.json')
        $deferOps=@($operations | Where-Object {$_.operation -eq 'defer-GPIO-Host' -and $_.exit_code -eq 0 -and $_.flags -eq 64})
        $filesOk=$false
        try{
            $expectedFiles=@($package.files | Where-Object {$_.path -match '^Drivers/(GPIO|Host)/[^/]+\.(inf|cat|sys)$'})
            if($expectedFiles.Count -ne 6 -or @($deferred.files).Count -ne 6){throw 'Incomplete deferred files'}
            foreach($file in $expectedFiles){
                $entry=@($deferred.files | Where-Object {$_.path -ceq $file.path -and $_.sha256 -eq $file.sha256})
                $copy=Join-Path $runtime ('deferred-driver-set/'+[IO.Path]::GetFileName($file.path))
                if($entry.Count -ne 1 -or !(Test-Path $copy) -or (Get-FileHash $copy).Hash -ine $file.sha256){throw 'Deferred evidence file mismatch'}
            }
            $filesOk=$true
        }catch{}
        $deferredOk=$filesOk -and $prepared -and $deferred -and $gates -and
            $prepared.attempt_id -eq $epoch.attempt_id -and $deferred.attempt_id -eq $epoch.attempt_id -and
            $gates.attempt_id -eq $epoch.attempt_id -and $gates.host -eq 0 -and $gates.provider -eq 0 -and
            $prepared.method -eq 'deferred-driver-set' -and $prepared.selected_driver_proven -eq $false -and
            $deferred.method -eq 'DiInstallDriverW/INSTALL_AS_SET' -and $deferred.flags -eq 64 -and
            $deferred.api_success -eq $true -and $deferred.selected_driver_proven -eq $false -and
            @($deferred.files).Count -eq 6 -and $deferOps.Count -eq 1 -and
            $complete -and $complete.mode -eq 'prepare' -and !$complete.error -and $complete.need_next_boot -eq $true
        Add-TouchGpioStep $steps 'deferred-driver-set' $(if($deferredOk){'proven'}else{'failed'}) `
            'API staging plus normal shutdown request only; selection and physical shutdown require postboot evidence'
        $required=@('runtime-attempt','boot-restore-windows','boot-namespace-gate','boot-ssdt-installed','boot-ssdt-readback',
            'boot-chainload-windows','trial-ssdt-visible-to-windows','no-iort-installed','runtime-no-error',
            'runtime-completed','runtime-clock-stable','valid-runtime-receipts','deferred-driver-set','supervisor-shutdown-request')
        $missing=@($required | Where-Object {!$steps.Contains($_) -or $steps[$_].status -ne 'proven'})
        $result['unproven_steps']=$missing
        $result['failed_steps']=@($required | Where-Object {$steps.Contains($_) -and $steps[$_].status -eq 'failed'})
        $result.verdict=if($missing.Count){'incomplete'}else{'prepared-awaiting-cold-selection'}
        $facts['hardware_tested']=$false
        return $result
    }
    # A step that is missing is not a proof. Only a fully proven chain may be
    # reported as hardware evidence, and only the user can confirm the tap.
    $core = @($ordered | Where-Object {$_ -ne 'tap-and-swipe'})
    $unproven = @($core | Where-Object {(!$steps.Contains($_)) -or $steps[$_].status -ne 'proven'})
    $failed = @($ordered | Where-Object {$steps.Contains($_) -and $steps[$_].status -eq 'failed'})
    $tapProven = $steps.Contains('tap-and-swipe') -and $steps['tap-and-swipe'].status -eq 'proven'
    $result['failed_steps'] = $failed
    $result['unproven_steps'] = $unproven
    if ($unproven.Count -eq 0) {
        $result['verdict'] = if ($tapProven) {'accepted'} else {'hardware-chain-proven-awaiting-user-confirmation'}
    } else {
        $result['verdict'] = 'incomplete'
    }
    return $result
}
