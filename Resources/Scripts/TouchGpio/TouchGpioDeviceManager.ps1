# SPDX-License-Identifier: BSD-2-Clause-Patent
# Opens Device Manager expanded in the interactive desktop session of the
# identified ARM64 V60 and shows a live status window with the state the
# GPIO touch driver wrote to the registry. This helper is display only: it
# installs nothing, changes no gate, writes no driver and never touches the
# boot path. It runs from the Startup folder, so it lives in the logged-on
# user session where a visible window is possible at all.
#
# The console tree is expanded through the tree view messages of the real
# SysTreeView32 window: UI Automation does not expose the MMC tree, so the
# expand pattern never matched anything. The keyboard fallback stays as the
# last resort.
#
# The status window and the rolling log are the evidence that survives a
# bugcheck: the registry values the driver wrote are still in the memory hive
# and are lost with the machine, but the log file is already on the disk.
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60') {throw 'Wrong machine'}
$marker = Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker'
if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') {throw 'Wrong installation'}
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') {throw 'Desktop required'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
$logs = Join-Path $env:SystemDrive 'TimelmLogs\TouchGpioTrial'
$null = New-Item -ItemType Directory -Path $logs -Force
$windowTitle = 'Device Manager'
$statusLog = Join-Path $logs 'driver-status.log'
$phases = New-Object 'System.Collections.Generic.List[object]'
if (-not ('TimelmConsole' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class TimelmConsole {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr handle, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessage(IntPtr handle, uint message, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr handle, StringBuilder name, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool SetWindowText(IntPtr handle, string text);
  public delegate bool EnumProc(IntPtr handle, IntPtr lParam);
}
'@
}

function Save-Phases {
    try {
        @($phases.ToArray()) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $logs 'device-manager-phases.json')
    } catch {}
}
function Get-DeviceManagerProcess {
    # The snap-in console is mmc.exe. Its main window title is the console
    # title, which the Device Manager snap-in sets to "Device Manager".
    foreach ($p in @(Get-Process -Name 'mmc' -ErrorAction SilentlyContinue)) {
        if ($p.MainWindowTitle -and $p.MainWindowTitle -match 'Device Manager') {return $p}
    }
    return $null
}
function Wait-DeviceManagerWindow([int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $p = Get-DeviceManagerProcess
        if ($p) {return $p}
        Start-Sleep -Milliseconds 500
    }
    return $null
}
function Send-Keys([string]$Keys) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        if (!$shell.AppActivate($windowTitle)) {return $false}
        Start-Sleep -Milliseconds 400
        $shell.SendKeys($Keys)
        return $true
    } catch {return $false}
}
function Get-ConsoleTree([IntPtr]$window) {
    # The MMC console tree is a plain SysTreeView32 window. It is found by
    # walking the child windows of the console, not by UI Automation.
    $script:treeHandle = [IntPtr]::Zero
    $callback = [TimelmConsole+EnumProc]{
        param([IntPtr]$handle, [IntPtr]$lParam)
        $name = New-Object System.Text.StringBuilder 256
        [void][TimelmConsole]::GetClassName($handle, $name, 256)
        if ($name.ToString() -eq 'SysTreeView32') {
            $script:treeHandle = $handle
            return $false
        }
        return $true
    }
    try { [void][TimelmConsole]::EnumChildWindows($window, $callback, [IntPtr]::Zero) } catch {}
    return $script:treeHandle
}
function Expand-TreeItem([IntPtr]$tree, [IntPtr]$item, [int]$Depth) {
    # TVM_EXPAND with TVE_EXPAND opens the node, TVM_GETNEXTITEM walks it.
    if ($item -eq [IntPtr]::Zero -or $Depth -gt 8) {return 0}
    $expanded = 0
    [void][TimelmConsole]::SendMessage($tree, 0x1102, [IntPtr]2, $item)
    $child = [TimelmConsole]::SendMessage($tree, 0x110A, [IntPtr]4, $item)
    while ($child -ne [IntPtr]::Zero) {
        $expanded += 1 + (Expand-TreeItem $tree $child ($Depth + 1))
        $child = [TimelmConsole]::SendMessage($tree, 0x110A, [IntPtr]1, $child)
    }
    return $expanded
}
function Expand-ConsoleTree {
    $result = [ordered]@{method='none';items=0;expanded=0;error=$null}
    try {
        $proc = Get-DeviceManagerProcess
        if (!$proc) {throw 'Device Manager window is gone'}
        $tree = Get-ConsoleTree $proc.MainWindowHandle
        if ($tree -eq [IntPtr]::Zero) {throw 'the console tree window was not found'}
        $root = [TimelmConsole]::SendMessage($tree, 0x110A, [IntPtr]0, [IntPtr]::Zero)
        if ($root -eq [IntPtr]::Zero) {throw 'the console tree has no root node'}
        $result.expanded = Expand-TreeItem $tree $root 0
        $result.items = $result.expanded
        $result.method = 'treeview'
    } catch {
        $result.error = $_.Exception.Message
    }
    return $result
}
function Expand-DeviceManagerTree {
    # UI Automation is tried first, because it is the only way that can read
    # the node names. The MMC tree does not expose the expand pattern on this
    # build, so the tree view messages are the working path and the keyboard
    # shortcut is the last resort.
    $result = [ordered]@{method='none';items=0;expanded=0;passes=0;names=@();error=$null}
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $windowTitle)
        $itemCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TreeItem)
        $window = $null
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            $window = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
            if ($window) {
                $probe = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCondition)
                if ($probe.Count -gt 0) {break}
            }
            Start-Sleep -Milliseconds 500
        }
        if ($null -eq $window) {throw 'Device Manager window is not visible to UI Automation'}
        $seen = @{}
        for ($pass = 1; $pass -le 4; $pass++) {
            $items = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCondition)
            if ($items.Count -eq 0) {break}
            $result.passes = $pass
            $changed = 0
            for ($i = 0; $i -lt $items.Count; $i++) {
                $item = $items[$i]
                try {
                    $name = $item.Current.Name
                    if ($name -and !$seen.ContainsKey($name)) {$seen[$name] = $true; $result.names += $name}
                } catch {}
                try {
                    $pattern = $item.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
                    if ($pattern.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Expanded) {
                        $pattern.Expand()
                        $changed++
                    }
                    $result.expanded++
                } catch {}
            }
            $result.items = $seen.Count
            if ($changed -eq 0) {break}
            Start-Sleep -Milliseconds 400
        }
        $result.method = 'uia'
    } catch {
        $result.error = $_.Exception.Message
    }
    if ($result.expanded -eq 0) {
        $treeResult = Expand-ConsoleTree
        $result.method = $treeResult.method
        $result.expanded = $treeResult.expanded
        $result.items = $treeResult.items
        if ($treeResult.error) {$result.error = $treeResult.error}
    }
    if ($result.expanded -eq 0) {
        # Fall back to the tree's expand-all key. The console tree has to own
        # the keyboard focus for it, so the window is activated first.
        $result.method = 'keyboard'
        $null = Send-Keys '*'
        Start-Sleep -Seconds 3
    }
    return $result
}
function Show-DeviceManager([string]$Phase, [bool]$Refresh) {
    $summary = [ordered]@{phase=$Phase;utc=[DateTime]::UtcNow.ToString('o');refresh_requested=$Refresh;
        f5_sent=$false;uia_method='none';uia_expanded=0;uia_items=0;uia_error=$null;names=@()}
    $proc = Get-DeviceManagerProcess
    if (!$proc) {return $null}
    # The phone screen is small, so the console is maximized and brought to the
    # front. The user has to be able to read the tree while the trial runs.
    try {
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            [TimelmConsole]::ShowWindow($proc.MainWindowHandle, 3) | Out-Null
            [TimelmConsole]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
        }
    } catch {}
    if ($Refresh) {
        # F5 is the console refresh and the Device Manager hardware rescan. It
        # runs only after the trial published a phase receipt, so the rescan
        # never races the installation steps.
        $summary.f5_sent = Send-Keys '{F5}'
        Start-Sleep -Seconds 6
    }
    $expansion = Expand-DeviceManagerTree
    $summary.uia_method = $expansion.method
    $summary.uia_expanded = $expansion.expanded
    $summary.uia_items = $expansion.items
    $summary.uia_error = $expansion.error
    $summary.names = @($expansion.names | Select-Object -First 400)
    return $summary
}

# ---------------------------------------------------------------------------
# Live driver status. The registry values are read while the driver writes
# them, so the window shows the step the trial is in. The same lines are
# appended to a rolling log file, which is the only evidence that survives a
# bugcheck of the kernel.
# ---------------------------------------------------------------------------
$hostValueNames = @('TimelmHostStage','TimelmHostStatus','TimelmBitbangStage','TimelmBitbangStatus',
    'TimelmBitbangPinCount','TimelmBitbangPinId0','TimelmBitbangPinId1','TimelmBitbangPinId2',
    'TimelmBitbangPinId3','TimelmBitbangPinId4','TimelmBitbangIdleLines','TimelmBitbangIdentityStatus',
    'TimelmBitbangIdentity0','TimelmBitbangIdentity1','TimelmBitbangTransfers','TimelmBitbangFailures',
    'TimelmBitbangLastStatus','TimelmBitbangRetained','TimelmBitbangStopStatus','TimelmGeniFirmware',
    'TimelmGeniFifoDisabled','TimelmGeniState','TimelmIdleStatus','NativeGpioI2cEnabled',
    'NativeBoardInitEnabled','NativeGpiEnabled','WindowsIommuEnabled','FirmwareHandoffVerified',
    'SourceClockHz','ReadOnlyHardwareProbeEnabled')
function Get-ParameterValues([string]$HardwareId) {
    $values = [ordered]@{}
    try {
        $root = "HKLM:\SYSTEM\CurrentControlSet\Enum\$HardwareId"
        foreach ($instance in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $parameters = Join-Path $instance.PSPath 'Device Parameters'
            if (!(Test-Path -LiteralPath $parameters)) {continue}
            $item = Get-ItemProperty -LiteralPath $parameters -ErrorAction SilentlyContinue
            if (!$item) {continue}
            foreach ($property in $item.PSObject.Properties) {
                if ($property.Name -like 'PS*') {continue}
                $values[$property.Name] = $property.Value
            }
        }
    } catch {}
    return $values
}
function Format-StatusLine([string]$Label, $Value) {
    if ($Value -is [uint32] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [uint64]) {
        return ('{0}={1} (0x{2:X})' -f $Label, $Value, [uint32]$Value)
    }
    return ('{0}={1}' -f $Label, $Value)
}
function Get-DriverStatus {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add(("Timelm GPIO touch status  {0}" -f (Get-Date -Format 'HH:mm:ss')))
    $lines.Add('ACPI\TIML0001 (touch host)')
    $host = Get-ParameterValues 'ACPI\TIML0001'
    if ($host.Count -eq 0) {$lines.Add('  device parameters: not present')}
    foreach ($name in $hostValueNames) {
        if ($host.Contains($name)) {$lines.Add('  ' + (Format-StatusLine $name $host[$name]))}
    }
    $lines.Add('ACPI\KONA1001 (GPIO provider)')
    $provider = Get-ParameterValues 'ACPI\KONA1001'
    foreach ($name in @('TouchBusGpioEnabled','TimelmGpioBitbangGate','TimelmGpioStage','TimelmGpioStatus')) {
        if ($provider.Contains($name)) {$lines.Add('  ' + (Format-StatusLine $name $provider[$name]))}
    }
    if ($provider.Count -eq 0) {$lines.Add('  device parameters: not present')}
    return $lines
}
function Write-StatusLog([string]$Text) {
    try {
        $info = Get-Item -LiteralPath $statusLog -ErrorAction SilentlyContinue
        if ($info -and $info.Length -gt 262144) {
            $keep = @(Get-Content -LiteralPath $statusLog -Tail 400 -ErrorAction SilentlyContinue)
            Set-Content -LiteralPath $statusLog -Value $keep -Encoding UTF8
        }
        Add-Content -LiteralPath $statusLog -Value $Text -Encoding UTF8
    } catch {}
}
function Disarm-Startup {
    # The helper removes its own Startup entry once the console is up, and only
    # when the entry is byte for byte the one this trial staged. A foreign
    # entry is never touched.
    $startup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\Timelm-device-manager.cmd'
    $staged = Join-Path $env:SystemDrive 'TimelmTools\TouchGpioTrial\Timelm-device-manager.cmd'
    if (!(Test-Path -LiteralPath $startup) -or !(Test-Path -LiteralPath $staged)) {return 'absent'}
    try {
        if ((Get-FileHash -LiteralPath $startup).Hash -ne (Get-FileHash -LiteralPath $staged).Hash) {return 'foreign-kept'}
        Remove-Item -LiteralPath $startup -Force
        return 'removed'
    } catch {return ('failed: ' + $_.Exception.Message)}
}
$script:watch = @('phase-gpio-started.json','phase-host-started.json','phase-test-window.json','trial-error.json','complete.json')
$script:seen = @{}
$script:done = $false
$script:statusText = ''
$script:deadline = (Get-Date).AddMinutes(25)
function Update-PhaseWatch {
    foreach ($name in $script:watch) {
        if ($script:seen[$name]) {continue}
        $path = Join-Path $logs $name
        if (!(Test-Path -LiteralPath $path)) {continue}
        $script:seen[$name] = $true
        Start-Sleep -Seconds 2
        $summary = Show-DeviceManager ($name -replace '\.json$','') $true
        if ($summary) {$phases.Add($summary)} else {$phases.Add([ordered]@{phase=$name;utc=[DateTime]::UtcNow.ToString('o');error='Device Manager window is gone'})}
        Save-Phases
    }
    if (Test-Path -LiteralPath (Join-Path $logs 'complete.json')) {$script:done = $true}
    if (Test-Path -LiteralPath (Join-Path $logs 'trial-error.json')) {$script:done = $true}
}
function Update-Status {
    $lines = Get-DriverStatus
    $text = ($lines -join "`r`n")
    if ($text -ne $script:statusText) {
        $script:statusText = $text
        Write-StatusLog (("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ($lines -join ' | ')))
    }
    return $text
}
try {
    $session = (Get-Process -Id $PID).SessionId
    $phases.Add([ordered]@{phase='helper-start';utc=[DateTime]::UtcNow.ToString('o');session_id=$session})
    Save-Phases
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\mmc.exe') -ArgumentList 'devmgmt.msc' -WorkingDirectory $env:SystemRoot | Out-Null
    $proc = Wait-DeviceManagerWindow 120
    if (!$proc) {throw 'Device Manager window did not appear'}
    Start-Sleep -Seconds 2
    $summary = Show-DeviceManager 'boot' $false
    $phases.Add($summary)
    $phases.Add([ordered]@{phase='startup-disarm';utc=[DateTime]::UtcNow.ToString('o');result=(Disarm-Startup)})
    Save-Phases
    # The status window shows the same lines that go into the rolling log. The
    # window is optional: without it the log file still carries the state.
    $form = $null
    $textBox = $null
    $timer = $null
    $withWindow = $false
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Timelm GPIO touch status'
        $form.TopMost = $true
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point(4, 4)
        $form.Size = New-Object System.Drawing.Size(620, 460)
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Multiline = $true
        $textBox.ReadOnly = $true
        $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
        $textBox.Font = New-Object System.Drawing.Font('Consolas', 9)
        $form.Controls.Add($textBox)
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $timer.Add_Tick({
            try {
                Update-PhaseWatch
                $text = Update-Status
                if ($textBox) {$textBox.Text = $text}
                if ($form) {$form.Text = ('Timelm GPIO touch status  ' + (Get-Date -Format 'HH:mm:ss'))}
                if ($script:done) {$timer.Stop(); $form.Close()}
            } catch {}
        })
        $form.Add_Shown({$timer.Start()})
        $withWindow = $true
    } catch {
        $withWindow = $false
    }
    if ($withWindow) {
        [System.Windows.Forms.Application]::Run($form)
    } else {
        while ((Get-Date) -lt $script:deadline -and !$script:done) {
            Update-PhaseWatch
            $null = Update-Status
            Start-Sleep -Seconds 1
        }
    }
    $phases.Add([ordered]@{phase='helper-end';utc=[DateTime]::UtcNow.ToString('o');session_id=$session;
        status_window=$withWindow;done=$script:done})
    Save-Phases
} catch {
    $phases.Add([ordered]@{phase='helper-error';utc=[DateTime]::UtcNow.ToString('o');error=$_.Exception.Message})
    Save-Phases
}
