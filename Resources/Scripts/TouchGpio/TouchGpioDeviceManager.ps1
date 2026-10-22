# SPDX-License-Identifier: BSD-2-Clause-Patent
# Opens Device Manager expanded in the interactive desktop session of the
# identified ARM64 V60, so the drivers Windows actually loaded can be watched
# while the GPIO touch trial runs. This helper is display only: it installs
# nothing, changes no gate, writes no driver and never touches the boot path.
# It runs from the Startup folder, so it lives in the logged-on user session
# where a visible window is possible at all.
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60') {throw 'Wrong machine'}
$marker = Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker'
if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') {throw 'Wrong installation'}
if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') {throw 'Desktop required'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
$logs = Join-Path $env:SystemDrive 'TimelmLogs\TouchGpioTrial'
$null = New-Item -ItemType Directory -Path $logs -Force
$windowTitle = 'Device Manager'
$phases = New-Object 'System.Collections.Generic.List[object]'
if (-not ('TimelmConsole' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TimelmConsole {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr handle, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr handle);
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
function Expand-DeviceManagerTree {
    # UI Automation is the deterministic way to expand the console tree: every
    # node that reports an expand/collapse pattern is expanded directly. The
    # keyboard shortcut (the tree's expand-all key) is only a fallback, because
    # it depends on the console tree owning the keyboard focus.
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
        # The snap-in needs a moment before its tree exists, so the console
        # tree is polled instead of assumed.
        $window = $null
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
            $window = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
            if ($window) {
                $probe = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCondition)
                if ($probe.Count -gt 0) {break}
            }
            Start-Sleep -Milliseconds 500
        }
        if ($null -eq $window) {throw 'Device Manager window is not visible to UI Automation'}
        $treeCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Tree)
        $trees = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $treeCondition)
        for ($t = 0; $t -lt $trees.Count; $t++) {
            try {$trees[$t].SetFocus()} catch {}
        }
        $seen = @{}
        for ($pass = 1; $pass -le 8; $pass++) {
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
    if ($expansion.expanded -eq 0) {
        # Fall back to the tree's expand-all key. The console tree has to own
        # the keyboard focus for it, so the window is activated first.
        $summary.f5_sent = (Send-Keys '*')
        Start-Sleep -Seconds 3
    }
    return $summary
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
    # The trial publishes a receipt at every hardware phase. Each one refreshes
    # the console, so the tree shows the devices that exist after the driver
    # that phase installed.
    $watch = @('phase-gpio-started.json','phase-host-started.json','phase-test-window.json','trial-error.json','complete.json')
    $seen = @{}
    $deadline = (Get-Date).AddMinutes(25)
    while ((Get-Date) -lt $deadline) {
        foreach ($name in $watch) {
            if ($seen[$name]) {continue}
            $path = Join-Path $logs $name
            if (!(Test-Path -LiteralPath $path)) {continue}
            $seen[$name] = $true
            Start-Sleep -Seconds 2
            $summary = Show-DeviceManager ($name -replace '\.json$','') $true
            if ($summary) {$phases.Add($summary)} else {$phases.Add([ordered]@{phase=$name;utc=[DateTime]::UtcNow.ToString('o');error='Device Manager window is gone'})}
            Save-Phases
        }
        if (Test-Path -LiteralPath (Join-Path $logs 'complete.json')) {break}
        if (Test-Path -LiteralPath (Join-Path $logs 'trial-error.json')) {break}
        Start-Sleep -Seconds 5
    }
    $phases.Add([ordered]@{phase='helper-end';utc=[DateTime]::UtcNow.ToString('o');session_id=$session})
    Save-Phases
} catch {
    $phases.Add([ordered]@{phase='helper-error';utc=[DateTime]::UtcNow.ToString('o');error=$_.Exception.Message})
    Save-Phases
}
