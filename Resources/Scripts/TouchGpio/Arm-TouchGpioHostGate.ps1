# PC-side helper. Arms the trial's own host gate in the phone's SYSTEM hive.
#
# The host driver reads NativeGpioI2cEnabled from the device parameters of
# ACPI\TIML0001 when the device starts, and only a value of 1 takes the GPIO
# bitbang path (BbWindowsPrepare). The device starts in the very boot that
# carries the trial SSDT, so the gate has to be in the hive before that boot.
# It cannot be written while the phone runs: a device that failed to start
# keeps the PnP lock of its parameters key, and every write to that key waits
# for the retry loop of the failing device.
#
# The phone must therefore be off (mass storage) while this runs. The hive is
# checked for a lock before it is touched, and every value is read back.
param(
    [Parameter(Mandatory=$true)][string]$WindowsRoot,
    [Parameter(Mandatory=$true)][string]$Receipt,
    [int]$GateValue = 1,
    # A resumed attempt binds one boot to one attempt id: the adapter reads
    # this DWORD from the device key at the first start of the boot and
    # publishes it as TimelmBitbangAttempt. Zero means "not armed here".
    [int]$AttemptId = 0,
    # The SHA-256 of the bundle's own host INF. When set, the script follows
    # the device's own Driver reference into the Class tree and hashes the
    # INF the device actually selected. An INF that merely sits in the store
    # is not the selected package; trial 9 refused a bundle over exactly
    # that difference, so the resume decision has to come from here.
    [string]$BundleInfHash = '')
$ErrorActionPreference = 'Stop'
$device = 'ACPI\TIML0001'
$instance = 'e'
$gateName = 'NativeGpioI2cEnabled'
$zeroGates = 'NativeBoardInitEnabled','NativeGpiEnabled','WindowsIommuEnabled',
             'FirmwareHandoffVerified','SourceClockHz','ReadOnlyHardwareProbeEnabled'
$mountReg = 'HKLM\TIMELM_TOUCHGPIO'
$mountKey = 'HKLM:\TIMELM_TOUCHGPIO'
$hive = Join-Path $WindowsRoot 'Windows\System32\config\SYSTEM'

if (!(Test-Path -LiteralPath $hive)) {throw 'Phone SYSTEM hive not found'}

function Invoke-Reg([string[]]$Arguments) {
    $output = & reg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {throw "reg.exe $($Arguments -join ' ') failed: $output"}
    return $output
}
function Remove-Mount() {
    # Every start clears any mount this trial family left behind, and the
    # removal is verified instead of assumed: a mount whose keys are still
    # referenced keeps the hive file locked, and the phone-off check below
    # or the after-unload hash would then fight a live mount. reg.exe
    # reports a missing mount with a failing exit code on stderr, and the
    # script's strict error preference must not turn that harmless
    # nothing-to-unload report into a staging failure.
    $preference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & reg.exe unload $mountReg 2>&1 | Out-Null
        $removed = $false
        foreach ($i in 1..5) {
            $null = & reg.exe query $mountReg 2>&1
            if ($LASTEXITCODE -ne 0) {$removed = $true; break}
            # A registry provider handle still held open is released by a
            # collection pass; reg.exe itself cannot free it.
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            & reg.exe unload $mountReg 2>&1 | Out-Null
            Start-Sleep -Milliseconds 250
        }
    } finally {
        $ErrorActionPreference = $preference
    }
    $global:LASTEXITCODE = 0
    if (!$removed) {throw ('Mounted hive ' + $mountReg + ' would not release; a key is still open')}
}
# A stale mount from a failed attempt keeps the loaded hive file locked: the
# mount is cleared BEFORE the phone-off check so that check measures the hive
# outside of this trial's own leftovers.
$null = Remove-Mount
$hiveHashBefore = (Get-FileHash -LiteralPath $hive -Algorithm SHA256).Hash
$locked = $false
try {
    $stream = [IO.File]::Open($hive,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $stream.Close()
} catch {
    if ($_.Exception.GetBaseException() -is [System.IO.IOException]) {$locked = $true} else {throw}
}
if ($locked) {throw 'The phone SYSTEM hive is in use; stop the phone Windows before the gate is armed'}

function Get-GateValues([string]$KeyPath) {
    $values = @{}
    if (!(Test-Path -LiteralPath $KeyPath)) {return $values}
    foreach ($name in (@($gateName) + $zeroGates + @('TimelmTouchAttemptId'))) {
        $item = Get-ItemProperty -LiteralPath $KeyPath -Name $name -ErrorAction SilentlyContinue
        if ($item -and ($item.PSObject.Properties.Name -contains $name)) {$values[$name] = [int]$item.$name}
    }
    return $values
}

$null = Remove-Mount
$null = Invoke-Reg @('load',$mountReg,$hive)
try {
    $select = Get-ItemProperty -LiteralPath ($mountKey + '\Select') -ErrorAction SilentlyContinue
    if (!$select) {throw 'Phone SYSTEM hive has no Select key'}
    $current = [int]$select.Current
    if ($current -lt 1 -or $current -gt 5) {throw "Unexpected ControlSet number $current"}
    $relative = 'ControlSet00' + $current + '\Enum\' + $device + '\' + $instance + '\Device Parameters'
    $keyReg = $mountReg + '\' + $relative
    $keyKey = $mountKey + '\' + $relative
    if (!(Test-Path -LiteralPath $keyKey)) {throw 'Host device parameters key not found in the phone hive'}
    $before = Get-GateValues $keyKey
    foreach ($name in $zeroGates) {
        $null = Invoke-Reg @('add',$keyReg,'/v',$name,'/t','REG_DWORD','/d','0','/f')
    }
    $null = Invoke-Reg @('add',$keyReg,'/v',$gateName,'/t','REG_DWORD','/d',[string]$GateValue,'/f')
    if ($AttemptId -gt 0) {
        if ($AttemptId -gt 4294967295) {throw 'Attempt id does not fit a DWORD'}
        $null = Invoke-Reg @('add',$keyReg,'/v','TimelmTouchAttemptId','/t','REG_DWORD','/d',[string]$AttemptId,'/f')
    }
    # The device's selected package decides a resumed attempt: follow the
    # Enum binding into the Class tree and hash the INF file the device is
    # actually bound to, not whichever INF happens to sit in the store. The
    # tree itself is read in reg.exe: the provider would hold hundreds of
    # enumeration keys open behind the GC and refuse the unload of this hive.
    $selected = [ordered]@{matches=$false;driver='';node='';inf='';inf_path='';inf_sha256='';nodes_scanned=0}
    if ($BundleInfHash) {
        $infRoot = Join-Path (Join-Path $WindowsRoot 'Windows') 'INF'
        $enumKey = $mountReg + '\ControlSet00' + $current + '\Enum\' + $device + '\' + $instance
        foreach ($line in @(Invoke-Reg @('query',$enumKey))) {
            if ($line -match '^\s+Driver\s+REG_(?:SZ|EXPAND_SZ)\s+(.+)$') {$selected.driver = $Matches[1].Trim()}
        }
        $classKey = $mountReg + '\ControlSet00' + $current + '\Control\Class'
        $nodes = @()
        foreach ($line in @(Invoke-Reg @('query',$classKey,'/s'))) {
            if ($line.Trim().Length -gt 0 -and !$line.StartsWith('    ')) {
                $nodes += @{name=([string]$line.Trim()).Split('\')[-1];values=@{}}
                continue
            }
            if (!$nodes.Count) {continue}
            $values = $nodes[-1].values
            $match = [regex]::Match($line, '^\s{3,4}([^\s]+?)\s+REG_(?:DWORD|SZ|EXPAND_SZ|BINARY|MULTI_SZ)\s+(.*)$')
            if ($match.Success) {$values[[string]$match.Groups[1].Value] = [string]$match.Groups[2].Value.TrimEnd()}
        }
        foreach ($node in $nodes) {
            $values = $node.values
            if (!$values.ContainsKey('MatchingDeviceId') -or $values['MatchingDeviceId'] -ne $device) {continue}
            $selected.nodes_scanned++
            $infName = ''
            foreach ($name in @('InfPath','DriverInfPath')) {
                if ($values.ContainsKey($name) -and $values[$name]) {$infName = $values[$name]; break}
            }
            if (!$infName) {continue}
            $infFile = Join-Path $infRoot $infName
            $infHash = ''
            if (Test-Path -LiteralPath $infFile) {$infHash = (Get-FileHash -LiteralPath $infFile).Hash}
            if ($infHash -ieq $BundleInfHash) {
                $selected.matches = $true
                $selected.node = $node.name
                $selected.inf = $infName
                $selected.inf_path = $infFile
                $selected.inf_sha256 = $infHash
                break
            }
            if (!$selected.node) {
                # Only a reference candidate to show which binding the
                # device held instead of the bundle.
                $selected.node = $node.name
                $selected.inf = $infName
                $selected.inf_path = $infFile
                $selected.inf_sha256 = $infHash
            }
        }
    }
    $after = Get-GateValues $keyKey
} finally {
    $null = Remove-Mount
}

$null = Invoke-Reg @('load',$mountReg,$hive)
try {
    $readBack = Get-GateValues ($mountKey + '\ControlSet00' + $current + '\Enum\' + $device + '\' + $instance + '\Device Parameters')
} finally {
    $null = Remove-Mount
}
if ($readBack[$gateName] -ne $GateValue) {throw 'Host gate readback failed'}
foreach ($name in $zeroGates) {
    if ($readBack[$name] -ne 0) {throw "Host gate $name is not zero"}
}
if ($AttemptId -gt 0 -and $readBack['TimelmTouchAttemptId'] -ne $AttemptId) {throw 'Host attempt id readback failed'}
$hiveHashAfter = (Get-FileHash -LiteralPath $hive -Algorithm SHA256).Hash
[ordered]@{phase='host-gate-armed';utc=[DateTime]::UtcNow.ToString('o');device=$device;instance=$instance;
    control_set=('ControlSet00'+$current);key=('ControlSet00'+$current+'\Enum\'+$device+'\'+$instance+'\Device Parameters');
    gate=$gateName;value=$GateValue;attempt_id=$AttemptId;attempt_id_readback=$readBack['TimelmTouchAttemptId'];
    selected_inf_match=$selected;before=$before;after=$after;readback=$readBack;
    hive_sha256_before=$hiveHashBefore;hive_sha256_after=$hiveHashAfter} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Receipt -Encoding UTF8
"host gate $gateName=$GateValue armed for $device ($instance) in ControlSet00$current (selected_inf_match=$($selected.matches), attempt_id=$AttemptId)"
