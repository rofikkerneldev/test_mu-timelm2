# Isolated SYSTEM child. No live device install, restart, rescan or automatic reboot.
$ErrorActionPreference='Stop'
if($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -or $env:COMPUTERNAME -ne 'TIMELM-V60'){throw 'Wrong machine'}
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'Phone SYSTEM task identity required'}
if((Get-Content (Join-Path $env:SystemDrive 'TimelmTools\OobeHelper\timelm-device.marker') -Raw).Trim() -ne 'LG-V60-timelm-8509C01F'){throw 'Wrong installation'}
if(Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'){throw 'Desktop required'}
. (Join-Path $PSScriptRoot 'TouchGpioCommon.ps1')
. (Join-Path $PSScriptRoot 'TouchGpioDeferred.ps1')
$plan=Get-Content (Join-Path $PSScriptRoot 'activation-plan.json') -Raw | ConvertFrom-Json
if($plan.schema -ne 2 -or $plan.mode -ne 'prepare' -or !$plan.attempt_id -or
    $plan.host_gate -ne 0 -or $plan.provider_gate -ne 0 -or $plan.expected_build_id -ne 539365412){throw 'Prepare-only deferred install'}
foreach($device in @(@('TIML0001\e','NativeGpioI2cEnabled'),@('KONA1001\0','TouchBusGpioEnabled'))){
    $path='HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\'+$device[0]+'\Device Parameters'
    if((Get-ItemPropertyValue -LiteralPath $path -Name $device[1]) -ne 0){throw 'Prepare gate is not zero'}
}
$setup=Get-ItemProperty 'HKLM:\SYSTEM\Setup'
if($setup.SystemSetupInProgress -ne 0 -or $setup.OOBEInProgress -ne 0){throw 'Setup incomplete'}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TimelmDeferredDriver {
  [DllImport("newdev.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  public static extern bool DiInstallDriverW(IntPtr parent, string directory, uint flags,
    [MarshalAs(UnmanagedType.Bool)] out bool needReboot);
}
'@
$install={param($directory,$flags)
    $reboot=$false
    $ok=[TimelmDeferredDriver]::DiInstallDriverW([IntPtr]::Zero,$directory,$flags,[ref]$reboot)
    $errorCode=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
    return @{success=$ok;need_reboot=$reboot;win32_error=$errorCode}
}
$logs=Join-Path $env:SystemDrive 'TimelmLogs\TouchGpioTrial'
$osBuild=[int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
$result=Invoke-TouchGpioDeferredInstall -Root $PSScriptRoot -Destination (Join-Path $logs 'deferred-driver-set') `
    -AttemptId $plan.attempt_id -OsBuild $osBuild -Install $install
Write-TouchGpioJson (Join-Path $logs 'deferred-result.json') $result
