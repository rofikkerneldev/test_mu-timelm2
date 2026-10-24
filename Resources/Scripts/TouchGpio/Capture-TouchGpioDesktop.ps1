# Runs only in the phone's interactive session, as a bounded diagnostic child.
param([ValidatePattern('^[a-z0-9-]{1,48}$')][string]$Phase='boot')
$ErrorActionPreference='Stop'
if($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60'){throw 'Wrong machine'}
if((Get-Content (Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker') -Raw).Trim() -ne 'LG-V60-timelm-8509C01F'){throw 'Wrong installation'}
if(Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'){throw 'Desktop required'}
$session=(Get-Process -Id $PID).SessionId
if($session -eq 0 -or ![Environment]::UserInteractive){throw 'Interactive phone desktop required'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
$null=Get-TouchGpioManifest $PSScriptRoot
$plan=Get-Content (Join-Path $PSScriptRoot 'activation-plan.json') -Raw | ConvertFrom-Json
if($plan.schema -ne 2 -or $plan.attempt_id -le 0){throw 'Invalid screenshot attempt'}
$logs=Join-Path $env:SystemDrive 'TimelmLogs\TouchGpioTrial'
$folder=Join-Path $logs 'screenshots';$null=New-Item -ItemType Directory -Path $folder -Force
$receipt=Join-Path $folder ($Phase+'.json')
if(Test-Path -LiteralPath $receipt){throw 'Screenshot phase already recorded'}
$record=[ordered]@{attempt_id=$plan.attempt_id;phase=$Phase;utc=[DateTime]::UtcNow.ToString('o');session_id=$session;
    device_id='ACPI\TIML0001\e';device_name=$null;properties_target_verified=$false;properties_error=$null;images=@();error=$null}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TimelmCaptureWindow {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
function Save-Desktop([string]$Name){
    $bounds=[Windows.Forms.SystemInformation]::VirtualScreen
    if($bounds.Width -le 0 -or $bounds.Height -le 0){throw 'No visible desktop surface'}
    $bitmap=New-Object Drawing.Bitmap($bounds.Width,$bounds.Height)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    $path=Join-Path $folder ($Phase+'-'+$Name+'.png')
    try{
        $graphics.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size)
        $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
    }finally{$graphics.Dispose();$bitmap.Dispose()}
    $check=[Drawing.Image]::FromFile($path)
    try{
        $record.images+=@{path=('screenshots/'+[IO.Path]::GetFileName($path));sha256=(Get-FileHash $path).Hash.ToLowerInvariant();
            bytes=(Get-Item $path).Length;width=$check.Width;height=$check.Height;kind=$Name}
    }finally{$check.Dispose()}
}
try{
    $console=@(Get-Process -Name mmc -ErrorAction SilentlyContinue | Where-Object {$_.SessionId -eq $session -and $_.MainWindowTitle -match 'Device Manager'}) | Select-Object -First 1
    if(!$console){
        # Visible UI is intentional: this is the requested Device Manager capture.
        $null=Start-Process -FilePath "$env:SystemRoot\System32\mmc.exe" -ArgumentList 'devmgmt.msc' -PassThru
        for($i=0;$i -lt 20 -and !$console;$i++){
            Start-Sleep -Milliseconds 250
            $console=@(Get-Process -Name mmc -ErrorAction SilentlyContinue | Where-Object {$_.SessionId -eq $session -and $_.MainWindowTitle -match 'Device Manager'}) | Select-Object -First 1
        }
    }
    if(!$console){throw 'Device Manager did not expose a window'}
    $null=[TimelmCaptureWindow]::ShowWindow($console.MainWindowHandle,3)
    $null=[TimelmCaptureWindow]::SetForegroundWindow($console.MainWindowHandle)
    $shell=New-Object -ComObject WScript.Shell
    if(!$shell.AppActivate($console.Id)){throw 'Could not activate Device Manager'}
    # Expand only. Never send F5: Device Manager treats it as a hardware rescan.
    $shell.SendKeys('*');Start-Sleep -Milliseconds 500
    Save-Desktop 'device-manager'
    try{
        $node=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\TIML0001\e'
        $deviceName=if($node.FriendlyName){[string]$node.FriendlyName}else{([string]$node.DeviceDesc -split ';')[-1]}
        if([string]::IsNullOrWhiteSpace($deviceName)){throw 'Host display name absent'}
        $record.device_name=$deviceName
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $window=[Windows.Automation.AutomationElement]::FromHandle($console.MainWindowHandle)
        $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$deviceName)
        $item=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
        if($item){
            $item.SetFocus()
            try{$select=$item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern);$select.Select()}catch{}
            $record.selection_method='uia-display-name'
        }else{
            # MMC can hide tree items from UIA. Its incremental keyboard search
            # still works; a matching Properties title must verify the result.
            $escaped=[regex]::Replace($deviceName,'[+^%~(){}\[\]]', {param($m) '{'+$m.Value+'}'})
            $shell.SendKeys('{HOME}');$shell.SendKeys($escaped)
            $record.selection_method='keyboard-display-name'
        }
        $shell.SendKeys('%{ENTER}');Start-Sleep -Milliseconds 750
        $dialog=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,($deviceName+' Properties')))
        if(!$dialog){throw 'Exact host Properties window was not verified'}
        $record.properties_target_verified=$true
        $record.properties_verification='host display name matched; inspect Details for instance ID'
        Save-Desktop 'host-properties'
        $texts=$dialog.FindAll([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Text))
        $record.properties_text=@($texts | ForEach-Object {$_.Current.Name} | Where-Object {$_} | Select-Object -First 60)
        $shell.SendKeys('{ESC}')
    }catch{$record.properties_error=$_.Exception.Message}
}catch{$record.error=$_.Exception.Message}
finally{Write-TouchGpioJson $receipt $record}
