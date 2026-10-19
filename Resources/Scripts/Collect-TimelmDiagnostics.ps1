# Diagnostic queries only. Output goes to the Windows partition; ESP is read
# through a temporary mount point and immediately detached. No driver install,
# registry writes, BCD edits, device resets, or event-channel enablement.
param(
    [string]$OutputRoot = "$env:SystemDrive\TimelmLogs",
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
Capture 'boot-options' { Native 'boot-options' 'bcdedit.exe' @('/enum','all') }
Capture 'graphics-registry' { Native 'graphics-registry' 'reg.exe' @('query','HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration','/s') }
Capture 'user-dpi' { Native 'user-dpi' 'reg.exe' @('query','HKCU\Control Panel\Desktop','/v','LogPixels') }
Capture 'per-monitor-dpi' { Native 'per-monitor-dpi' 'reg.exe' @('query','HKCU\Control Panel\Desktop\PerMonitorSettings','/s') }
foreach ($channel in @('System','Application','Microsoft-Windows-Kernel-PnP/Configuration','Microsoft-Windows-DriverFrameworks-UserMode/Operational')) {
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
        foreach ($name in @('timelm-i2c-clockdiag.txt','timelm-ufsdiag-v2.txt')) {
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
