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
    [int]$GateValue = 1)
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
$hiveHashBefore = (Get-FileHash -LiteralPath $hive -Algorithm SHA256).Hash
$locked = $false
try {
    $stream = [IO.File]::Open($hive,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $stream.Close()
} catch [IO.IOException] { $locked = $true }
if ($locked) {throw 'The phone SYSTEM hive is in use; stop the phone Windows before the gate is armed'}

function Invoke-Reg([string[]]$Arguments) {
    $output = & reg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {throw "reg.exe $($Arguments -join ' ') failed: $output"}
    return $output
}
function Remove-Mount() {
    # A stale mount is removed on a best effort basis: the phone hive is the
    # only thing that matters here, a leftover mount would block the load.
    & reg.exe unload $mountReg 2>&1 | Out-Null
}
function Get-GateValues([string]$KeyPath) {
    $values = @{}
    if (!(Test-Path -LiteralPath $KeyPath)) {return $values}
    foreach ($name in @($gateName) + $zeroGates) {
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
$hiveHashAfter = (Get-FileHash -LiteralPath $hive -Algorithm SHA256).Hash
[ordered]@{phase='host-gate-armed';utc=[DateTime]::UtcNow.ToString('o');device=$device;instance=$instance;
    control_set=('ControlSet00'+$current);key=('ControlSet00'+$current+'\Enum\'+$device+'\'+$instance+'\Device Parameters');
    gate=$gateName;value=$GateValue;before=$before;after=$after;readback=$readBack;
    hive_sha256_before=$hiveHashBefore;hive_sha256_after=$hiveHashAfter} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Receipt -Encoding UTF8
"host gate $gateName=$GateValue armed for $device ($instance) in ControlSet00$current"
