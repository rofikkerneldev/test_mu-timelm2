# Diagnostic queries only. Output goes to the Windows partition; ESP is read
# through a temporary mount point and immediately detached. No driver install,
# registry writes, BCD edits, device resets, or event-channel enablement.
param(
    [string]$OutputRoot = "$env:SystemDrive\TimelmLogs",
    [switch]$SkipEsp,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'

function Quote-NativeArgument([string]$Value) {
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

$displaySource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class TimelmDisplay {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct Mode {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
    public ushort SpecVersion, DriverVersion, Size, DriverExtra;
    public uint Fields;
    public int PositionX, PositionY;
    public uint Orientation, FixedOutput;
    public short Color, Duplex, YResolution, TTOption, Collate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string FormName;
    public ushort LogPixels;
    public uint BitsPerPixel, Width, Height, Flags, Frequency;
    public uint ICMMethod, ICMIntent, MediaType, DitherType, Reserved1, Reserved2;
    public uint PanningWidth, PanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  static extern bool EnumDisplaySettings(string device, int index, ref Mode mode);
  [DllImport("user32.dll")] static extern uint GetDpiForSystem();
  [DllImport("user32.dll")] static extern IntPtr GetThreadDpiAwarenessContext();
  [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr value);
  public static int ModeSize() { return Marshal.SizeOf(typeof(Mode)); }
  public static object Query() {
    var result = new Dictionary<string, object>();
    Mode mode = new Mode(); mode.Size = (ushort)ModeSize();
    bool ok = EnumDisplaySettings(null, -1, ref mode);
    result["CurrentModeAvailable"] = ok;
    if (ok) {
      result["NativeWidth"] = mode.Width; result["NativeHeight"] = mode.Height;
      result["Orientation"] = mode.Orientation; result["FrequencyHz"] = mode.Frequency;
      result["BitsPerPixel"] = mode.BitsPerPixel;
    }
    result["DpiForSystemInCollectorContext"] = GetDpiForSystem();
    result["CollectorDpiAwareness"] = GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext());
    result["DpiNote"] = "DPI is process-context dependent; unaware processes may report 96. No scaling was changed.";
    return result;
  }
}
public static class TimelmAcpi {
  // Provider is the C multi-character constant 'ACPI'. Table IDs below are
  // returned by Windows and passed back unchanged (little endian signatures).
  const uint Provider = 0x41435049;
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern uint EnumSystemFirmwareTables(uint provider, [Out] byte[] data, uint size);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern uint GetSystemFirmwareTable(uint provider, uint id, [Out] byte[] data, uint size);
  public static uint[] Enumerate() {
    uint size = EnumSystemFirmwareTables(Provider, null, 0);
    if (size == 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    if (size > 65536 || (size & 3) != 0) throw new InvalidOperationException("Invalid ACPI enumeration length");
    byte[] data = new byte[size];
    if (EnumSystemFirmwareTables(Provider, data, size) != size)
      throw new InvalidOperationException("ACPI table list changed or could not be read");
    uint[] ids = new uint[size / 4];
    for (int i = 0; i < ids.Length; ++i) ids[i] = BitConverter.ToUInt32(data, i * 4);
    return ids;
  }
  public static byte[] Read(uint id) {
    uint size = GetSystemFirmwareTable(Provider, id, null, 0);
    if (size == 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    if (size < 36 || size > 16 * 1024 * 1024) throw new InvalidOperationException("Invalid ACPI table length");
    byte[] data = new byte[size];
    if (GetSystemFirmwareTable(Provider, id, data, size) != size)
      throw new InvalidOperationException("ACPI table changed or could not be read");
    if (BitConverter.ToUInt32(data, 0) != id || BitConverter.ToUInt32(data, 4) != size)
      throw new InvalidOperationException("ACPI header mismatch");
    return data;
  }
}
'@
Add-Type -TypeDefinition $displaySource
if ([TimelmDisplay]::ModeSize() -ne 220) { throw 'Unexpected DEVMODEW layout' }
if ($ValidateOnly) {
    if ((Quote-NativeArgument 'a b') -cne '"a b"' -or
        (Quote-NativeArgument 'a"b') -cne '"a\"b"' -or
        (Quote-NativeArgument 'C:\end\') -cne '"C:\end\\"') { throw 'Native argument quoting failed' }
    Write-Host 'PowerShell/C# validation passed; DEVMODEW is 220 bytes. No device collection was run.'
    return
}
if ('ARM64' -notin @($env:PROCESSOR_ARCHITECTURE, $env:PROCESSOR_ARCHITEW6432)) {
    throw 'Run this collector on the ARM64 phone, not the development PC.'
}
$folder = Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
$null = New-Item -ItemType Directory -Path $folder -Force
$steps = New-Object 'System.Collections.Generic.List[object]'
function Write-JsonFile([string]$Name, $Value) {
    ConvertTo-Json -InputObject $Value -Depth 10 | Set-Content -LiteralPath (Join-Path $folder $Name) -Encoding UTF8
}
function Capture([string]$Name, [scriptblock]$Action) {
    Write-Host "Collecting $Name"
    try {
        & $Action
        $steps.Add([pscustomobject]@{step=$Name;status='ok'})
    } catch {
        $_ | Out-String | Set-Content -LiteralPath (Join-Path $folder ($Name + '-error.txt')) -Encoding UTF8
        $steps.Add([pscustomobject]@{step=$Name;status='error';message=$_.Exception.Message})
    }
}
function Native([string]$Name, [string]$Executable, [string[]]$Arguments) {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = (@($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill(); $null = $process.WaitForExit(5000)
            throw "$Name timed out after 30 seconds"
        }
        ($stdout.Result + "`r`n" + $stderr.Result) |
            Set-Content -LiteralPath (Join-Path $folder ($Name + '.txt')) -Encoding UTF8
        if ($process.ExitCode -ne 0) { throw "$Name exited with $($process.ExitCode); see command output" }
    } finally { $process.Dispose() }
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-JsonFile 'session.json' ([ordered]@{utc=(Get-Date).ToUniversalTime().ToString('o');administrator=$admin;
    architecture=$env:PROCESSOR_ARCHITECTURE;windows=$env:windir;system_drive=$env:SystemDrive;
    powershell=$PSVersionTable.PSVersion.ToString();script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash})
Capture 'windows-version' {
    Write-JsonFile 'windows-version.json' (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
        Select-Object DisplayVersion,CurrentBuildNumber,UBR,BuildLabEx,EditionID,ProductName)
}
Capture 'acpi-table-list' {
    $script:acpiIds = @([TimelmAcpi]::Enumerate())
    $entries = @($script:acpiIds | Group-Object | ForEach-Object {
        $id = [uint32]$_.Name
        [ordered]@{id=$id;signature=[Text.Encoding]::ASCII.GetString([BitConverter]::GetBytes($id));count=$_.Count}
    })
    Write-JsonFile 'acpi-table-list.json' ([ordered]@{tables=$entries;
        note='Windows GetSystemFirmwareTable returns only the first table for a repeated signature.'})
}
# A narrow allowlist avoids exporting licensing tables or unrelated firmware data.
foreach ($signature in @('DSDT','SSDT','FACP','IORT','APIC','GTDT')) {
    Capture ('acpi-' + $signature) {
        $id = [BitConverter]::ToUInt32([Text.Encoding]::ASCII.GetBytes($signature), 0)
        # DSDT is reached through FADT, so it need not appear in the root-table
        # enumeration. Try its direct query; do not mistake that for no DSDT.
        if ($signature -ne 'DSDT' -and (!$script:acpiIds -or $id -notin $script:acpiIds)) { throw "$signature was not enumerated" }
        $bytes = [TimelmAcpi]::Read($id)
        [IO.File]::WriteAllBytes((Join-Path $folder ($signature + '.dat')), $bytes)
        $sum = 0
        foreach ($b in $bytes) { $sum = ($sum + $b) -band 255 }
        Write-JsonFile ($signature + '-validation.json') ([ordered]@{length=$bytes.Length;checksum_valid=($sum -eq 0);
            oem_table_id=[Text.Encoding]::ASCII.GetString($bytes,16,8);sha256=(Get-FileHash -LiteralPath (Join-Path $folder ($signature + '.dat'))).Hash})
    }
}
Capture 'display-native' { Write-JsonFile 'display-native.json' ([TimelmDisplay]::Query()) }
Capture 'display-controller' {
    Write-JsonFile 'display-controller.json' @(Get-CimInstance Win32_VideoController -OperationTimeoutSec 15 |
        Select-Object Name,PNPDeviceID,Status,DriverVersion,VideoModeDescription,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate)
}
Capture 'pnp-entities' {
    Write-JsonFile 'pnp-entities.json' @(Get-CimInstance Win32_PnPEntity -OperationTimeoutSec 15 |
        Select-Object Name,PNPDeviceID,PNPClass,Service,Status,ConfigManagerErrorCode,HardwareID,CompatibleID)
}
Capture 'connected-resources' { Native 'connected-resources' 'pnputil.exe' @('/enum-devices','/connected','/deviceids','/drivers','/stack','/resources') }
Capture 'problem-devices' { Native 'problem-devices' 'pnputil.exe' @('/enum-devices','/problem','/deviceids','/properties') }
Capture 'driver-packages' { Native 'driver-packages' 'pnputil.exe' @('/enum-drivers','/files') }
Capture 'touch-driver-diagnostics' {
    $values = foreach ($id in @('TIML0001','LGSW4290','KONA1001','KONA1002','KONA1003')) {
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\' + $id
        if (Test-Path -LiteralPath $path) {
            foreach ($instance in Get-ChildItem -LiteralPath $path) {
                foreach ($key in @($instance.PSPath, ($instance.PSPath + '\Device Parameters'))) {
                    if (Test-Path -LiteralPath $key) {
                        $properties = Get-ItemProperty -LiteralPath $key
                        foreach ($property in $properties.PSObject.Properties) {
                            if ($property.Name -like 'Timelm*' -or
                                $property.Name -in @('NativeBoardInitEnabled','NativeGpiEnabled','WindowsIommuEnabled','FirmwareHandoffVerified','SourceClockHz','ReadOnlyHardwareProbeEnabled','NativeGpioI2cEnabled','TouchBusGpioEnabled')) {
                                [pscustomobject]@{device=$id;key=$key;name=$property.Name;value=$property.Value}
                            }
                        }
                    }
                }
            }
        }
    }
    Write-JsonFile 'touch-driver-diagnostics.json' @($values)
}
Capture 'kona-geni-service' { Native 'kona-geni-service' 'reg.exe' @('query','HKLM\SYSTEM\CurrentControlSet\Services\kona_geni','/s') }
Capture 'platform-driver-states' {
    Write-JsonFile 'platform-driver-states.json' @(Get-CimInstance Win32_SystemDriver -OperationTimeoutSec 15 |
        Where-Object {$_.Name -in @('qcpep','GPIO','kona_geni','vhidmini','SpbCx','SPMI','PMIC')} |
        Select-Object Name,State,Started,StartMode,PathName)
}
Capture 'boot-options' { Native 'boot-options' 'bcdedit.exe' @('/enum','all') }
Capture 'graphics-registry' { Native 'graphics-registry' 'reg.exe' @('query','HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration','/s') }
Capture 'user-dpi' { Native 'user-dpi' 'reg.exe' @('query','HKCU\Control Panel\Desktop','/v','LogPixels') }
Capture 'per-monitor-dpi' { Native 'per-monitor-dpi' 'reg.exe' @('query','HKCU\Control Panel\Desktop\PerMonitorSettings','/s') }
foreach ($channel in @('System','Application','Microsoft-Windows-CodeIntegrity/Operational','Microsoft-Windows-Kernel-PnP/Configuration','Microsoft-Windows-DriverFrameworks-UserMode/Operational')) {
    $safe = $channel.Replace('/','-')
    Capture $safe { Native $safe 'wevtutil.exe' @('epl',$channel,(Join-Path $folder ($safe + '.evtx')),'/ow:true') }
}
Capture 'setup-logs' {
    foreach ($relative in @('INF\setupapi.dev.log','Panther\setupact.log','Panther\setuperr.log')) {
        $source = Join-Path $env:windir $relative
        if (Test-Path -LiteralPath $source) {
            if ((Get-Item -LiteralPath $source).Length -le 32MB) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $folder $relative.Replace('\','-'))
            } else {
                Get-Content -LiteralPath $source -Tail 5000 | Set-Content -LiteralPath (Join-Path $folder ($relative.Replace('\','-') + '-tail.txt')) -Encoding UTF8
            }
        }
    }
}
Capture 'esp-logs' {
    if ($SkipEsp) { return }
    if (-not $admin) { throw 'Administrator required for temporary ESP mapping' }
    $used = @([IO.Directory]::GetLogicalDrives() | ForEach-Object { $_.Substring(0,1) })
    $letter = @('Z','Y','X','W','V','U','T') | Where-Object { $_ -notin $used } | Select-Object -First 1
    if (-not $letter) { throw 'No free temporary drive letter' }
    Native 'esp-map' 'mountvol.exe' @(($letter + ':'),'/S')
    try {
        $esp = Get-Partition -DriveLetter $letter
        $windows = Get-Partition -DriveLetter $env:SystemDrive.Substring(0,1)
        if ($esp.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -or $esp.DiskNumber -ne $windows.DiskNumber) {
            throw 'Mapped ESP is not an ESP on the Windows disk; copy skipped'
        }
        foreach ($name in @('timelm-i2c-clockdiag.txt','timelm-ufsdiag-v2.txt','timelm-touch-dma-check.txt')) {
            $source = $letter + ':\' + $name
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $folder $name) }
        }
        $hashes = foreach ($relative in @('EFI\Microsoft\Boot\bootmgfw.efi','EFI\Boot\bootaa64.efi',
            'EFI\Microsoft\Boot\bootmgfw.timelm-i2c-original.efi','EFI\Boot\bootaa64.timelm-i2c-original.efi')) {
            $source = $letter + ':\' + $relative
            if (Test-Path -LiteralPath $source) { [pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath $source).Hash} }
        }
        Write-JsonFile 'esp-boot-file-hashes.json' @($hashes)
    } finally { Native 'esp-unmap' 'mountvol.exe' @(($letter + ':'),'/D') }
}
Write-JsonFile 'collection-status.json' ($steps.ToArray())
Write-Host "Saved diagnostics to $folder"
Write-Host 'Some items may be unavailable during OOBE; inspect collection-status.json.'
