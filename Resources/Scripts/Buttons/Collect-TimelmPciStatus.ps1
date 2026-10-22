<#
.SYNOPSIS
  Collects the status of the PCI, ACPI and I2C devices of the phone.

.DESCRIPTION
  The evidence of the touch driver needs the state of the buses that carry
  it.  The collector writes two files:

    pci-status.json   the machines of the report
    pci-status.txt    the same report for the eye

  The report has these parts:

    summary      the number of the devices of every class and the number of
                 the devices with a problem
    pci          every device of the class PCI with its status, its problem
                 code, its driver and the place in the bus
    problems     every device of every class with a problem code
    acpi         the devices of the class ACPI, the touch controller of the
                 phone is behind one of them
    i2c          the controllers of the class I2C and the devices on them
    registry     the entries of Enum\PCI and Enum\ACPI with their driver
                 and their device parameters
    events       the entries of the system log of the last boot that talk
                 about PCI, PCIe, WHEA, ACPI, I2C or the touch controller
    pnputil      the output of "pnputil /enum-devices /problem"

  The collector never fails the trial, a part that cannot be read is written
  into the report as an error.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Collect-TimelmPciStatus.ps1 -OutputDirectory C:\TimelmLogs\TimelmPciStatus
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $env:SystemDrive 'TimelmLogs\TimelmPciStatus'),
    [int]$EventCount = 400,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$script:Report = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o')
    computer = $env:COMPUTERNAME
    os = $null
    summary = [ordered]@{}
    pci = @()
    problems = @()
    acpi = @()
    i2c = @()
    registry = [ordered]@{}
    events = @()
    pnputil = ''
    errors = @()
}

function Write-Report {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Add-Error {
    param([string]$Message)
    $script:Report.errors += $Message
    Write-Report ("error: {0}" -f $Message)
}

#
# The devices of the machine.  The cmdlet of the PnP module is used, the
# class of the WMI falls back for a machine without the module.
#
function Get-AllDevices {
    $devices = @()
    try {
        $devices = @(Get-PnpDevice -ErrorAction Stop | Select-Object -Property *)
        Write-Report ("{0} devices from the PnP module" -f $devices.Count)
        return $devices
    } catch {
        Write-Report ("the PnP module is not there: {0}" -f $_.Exception.Message)
    }

    try {
        $devices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)
        Write-Report ("{0} devices from the WMI" -f $devices.Count)
        return $devices
    } catch {
        Add-Error ("the devices cannot be read: {0}" -f $_.Exception.Message)
    }

    return @()
}

#
# The values of a device, the names of the two sources are different.
#
# The cmdlet of the PnP module keeps the details of the device in the
# property "Problem", the WMI keeps them in the object itself.
#
function Get-DeviceValue {
    param($Device, [string]$Name)
    if ($null -eq $Device) { return $null }
    if ($Device.PSObject.Properties.Name -contains $Name) {
        return $Device.$Name
    }
    $problem = Get-DeviceValue -Device $Device -Name 'Problem'
    if ($null -ne $problem -and ($problem.PSObject.Properties.Name -contains $Name)) {
        return $problem.$Name
    }
    return $null
}

function Get-DeviceClass {
    param($Device)
    $value = Get-DeviceValue -Device $Device -Name 'Class'
    if ($value) { return [string]$value }
    $value = Get-DeviceValue -Device $Device -Name 'PNPClass'
    if ($value) { return [string]$value }
    return 'unknown'
}

function Get-DeviceStatus {
    param($Device)
    $value = Get-DeviceValue -Device $Device -Name 'Status'
    if ($value) { return [string]$value }
    $value = Get-DeviceValue -Device $Device -Name 'ConfigManagerErrorCode'
    if ($null -ne $value) { return ('CMRC=' + $value) }
    return 'unknown'
}

function Get-DeviceProblem {
    param($Device)
    $value = Get-DeviceValue -Device $Device -Name 'ConfigManagerErrorCode'
    if ($null -ne $value) { return [int]$value }
    $status = Get-DeviceStatus -Device $Device
    if ($status -and $status -ieq 'Error') { return -1 }
    return 0
}

function Get-DeviceLocation {
    param($Device)
    $value = Get-DeviceValue -Device $Device -Name 'LocationInfo'
    if ($value) { return [string]$value }
    $value = Get-DeviceValue -Device $Device -Name 'LocationInformation'
    if ($value) { return [string]$value }
    return ''
}

function ConvertTo-DeviceRecord {
    param($Device)

    $class = Get-DeviceClass -Device $Device
    $problem = Get-DeviceProblem -Device $Device

    return [ordered]@{
        class = $class
        instance_id = [string](Get-DeviceValue -Device $Device -Name 'InstanceId')
        name = [string](Get-DeviceValue -Device $Device -Name 'FriendlyName')
        status = Get-DeviceStatus -Device $Device
        problem_code = $problem
        location = Get-DeviceLocation -Device $Device
        driver = [string](Get-DeviceValue -Device $Device -Name 'DriverName')
        driver_version = [string](Get-DeviceValue -Device $Device -Name 'DriverVersion')
        driver_date = [string](Get-DeviceValue -Device $Device -Name 'DriverDate')
        service = [string](Get-DeviceValue -Device $Device -Name 'Service')
        manufacturer = [string](Get-DeviceValue -Device $Device -Name 'Manufacturer')
        parent = [string](Get-DeviceValue -Device $Device -Name 'Parent')
    }
}

#
# The bus of a PCI device, the place of the device in the bus.
#
function Get-BusLocation {
    param([string]$InstanceId)

    $bus = ''
    $device = ''
    $function = ''

    if ($InstanceId -match 'PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})&SUBSYS_([0-9A-F]{4})&REV_([0-9A-F]{2})') {
        $bus = 'unknown'
    }

    $pattern = 'PCI\\(?:VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}&(?:SUBSYS_[0-9A-F]{4}&)?REV_[0-9A-F]{2})\\([0-9A-F]{8})'
    if ($InstanceId -match $pattern) {
        $value = $Matches[1]
        $device = [Convert]::ToString([Convert]::ToInt32($value.Substring(4, 2), 16), 10)
        $function = [Convert]::ToString([Convert]::ToInt32($value.Substring(2, 2), 16), 10)
        $bus = [Convert]::ToString([Convert]::ToInt32($value.Substring(0, 2), 16), 10)
    }

    if (-not $bus) { return '' }
    return ('bus {0}, device {1}, function {2}' -f $bus, $device, $function)
}

$null = New-Item -ItemType Directory -Force -Path $OutputDirectory

Write-Report 'the devices of the machine'

try {
    $script:Report.os = [ordered]@{
        caption = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption
        version = [string]$env:PROCESSOR_ARCHITECTURE
    }
} catch {
    $script:Report.os = [ordered]@{ caption = $env:OS; version = $env:PROCESSOR_ARCHITECTURE }
}

$devices = Get-AllDevices

$records = @()
foreach ($device in $devices) {
    $records += ConvertTo-DeviceRecord -Device $device
}

#
# The summary.
#
$byClass = [ordered]@{}
$problemCount = 0
$phantomCount = 0
foreach ($record in $records) {
    if (-not $byClass.Contains($record.class)) {
        $byClass[$record.class] = 0
    }
    $byClass[$record.class] = $byClass[$record.class] + 1
    if ($record.problem_code -eq 45) {
        $phantomCount = $phantomCount + 1
    } elseif ($record.problem_code -ne 0) {
        $problemCount = $problemCount + 1
    }
}
$script:Report.summary = [ordered]@{
    devices = $records.Count
    classes = $byClass
    devices_with_a_problem = $problemCount
    devices_that_are_not_there = $phantomCount
}

#
# The devices of the bus PCI.  The class of a device of the bus is not
# always PCI, a root complex of the laptop shows up as a device of the
# class System.  The name of the instance is the reliable sign.
#
foreach ($record in $records) {
    if (-not $record.instance_id.StartsWith('PCI\')) { continue }
    $script:Report.pci += [ordered]@{
        instance_id = $record.instance_id
        name = $record.name
        class = $record.class
        status = $record.status
        problem_code = $record.problem_code
        bus = Get-BusLocation -InstanceId $record.instance_id
        driver = $record.driver
        driver_version = $record.driver_version
        service = $record.service
        location = $record.location
        parent = $record.parent
    }
}

#
# Every device with a problem, the class does not matter.  The code 45
# means that the device is not there, it is not a problem of the machine.
#
$phantomCount = 0
foreach ($record in $records) {
    if ($record.problem_code -eq 0) { continue }
    if ($record.problem_code -eq 45) {
        continue
    }
    $script:Report.problems += $record
}

#
# The devices of the class ACPI, the touch controller of the phone is behind
# one of them.
#
foreach ($record in $records) {
    if ($record.class -ne 'ACPI') { continue }
    $script:Report.acpi += $record
}

#
# The controllers of the class I2C and the devices on them.
#
foreach ($record in $records) {
    if ($record.class -ne 'I2C') { continue }
    $script:Report.i2c += $record
}

#
# The registry of the bus.  The entries of Enum\PCI carry the driver and the
# parameters of the device, the entries of Enum\ACPI carry the touch
# controller of the phone.
#
function Get-EnumReport {
    param([string]$Class)

    $result = @()
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $Class
    if (-not (Test-Path -LiteralPath $root)) {
        return $result
    }

    foreach ($deviceKey in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        foreach ($instanceKey in (Get-ChildItem -LiteralPath $deviceKey.PSPath -ErrorAction SilentlyContinue)) {
            $entry = [ordered]@{
                device = $deviceKey.PSChildName
                instance = $instanceKey.PSChildName
                values = [ordered]@{}
                parameters = [ordered]@{}
            }

            try {
                $properties = Get-ItemProperty -LiteralPath $instanceKey.PSPath -ErrorAction Stop
                foreach ($property in $properties.PSObject.Properties) {
                    if ($property.Name -like 'PS*') { continue }
                    $entry.values[$property.Name] = [string]$property.Value
                }
            } catch {
                $entry.values['error'] = $_.Exception.Message
            }

            $parameterPath = Join-Path $instanceKey.PSPath 'Device Parameters'
            if (Test-Path -LiteralPath $parameterPath) {
                try {
                    $parameters = Get-ItemProperty -LiteralPath $parameterPath -ErrorAction Stop
                    foreach ($property in $parameters.PSObject.Properties) {
                        if ($property.Name -like 'PS*') { continue }
                        $entry.parameters[$property.Name] = [string]$property.Value
                    }
                } catch {
                    $entry.parameters['error'] = $_.Exception.Message
                }
            }

            $result += $entry
        }
    }

    return $result
}

Write-Report 'the registry of the bus'
try {
    $script:Report.registry['pci'] = @(Get-EnumReport -Class 'PCI')
    $script:Report.registry['acpi'] = @(Get-EnumReport -Class 'ACPI')
} catch {
    Add-Error ("the registry of the bus cannot be read: {0}" -f $_.Exception.Message)
}

#
# The entries of the system log that talk about the buses.
#
Write-Report 'the entries of the system log'
try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System' } -MaxEvents $EventCount -ErrorAction Stop)
    $script:Report.events = @(
        foreach ($event in $events) {
            $text = ''
            try { $text = [string]$event.Message } catch { $text = '' }
            $provider = [string]$event.ProviderName
            $interesting = ($provider -match 'WHEA|Kernel-PnP|Kernel-Boot|ACPI|PCI|I2C|HID|DriverFrameworks') -or
                           ($text -match 'PCI|PCIe|WHEA|ACPI|I2C|GENI|SW42902|HID')
            if (-not $interesting) { continue }
            [ordered]@{
                utc = $event.TimeCreated.ToUniversalTime().ToString('o')
                id = $event.Id
                level = [string]$event.LevelDisplayName
                provider = $provider
                message = $text
            }
        }
    )
} catch {
    Add-Error ("the system log cannot be read: {0}" -f $_.Exception.Message)
}

#
# The devices with a problem, seen by pnputil.
#
Write-Report 'the devices with a problem of pnputil'
try {
    $output = & pnputil.exe /enum-devices /problem 2>&1
    $script:Report.pnputil = ($output -join [Environment]::NewLine)
} catch {
    $script:Report.pnputil = ('error: ' + $_.Exception.Message)
}

#
# The tables of the ACPI, the DSDT holds the description of the devices of
# the phone.
#
try {
    $acpi = [ordered]@{}
    foreach ($name in @('DSDT', 'FACP', 'APIC')) {
        $path = 'HKLM:\HARDWARE\ACPI\' + $name
        $acpi[$name] = (Test-Path -LiteralPath $path)
    }
    $script:Report.registry['acpi_tables'] = $acpi
} catch {
    Add-Error ("the tables of the ACPI cannot be read: {0}" -f $_.Exception.Message)
}

#
# The files of the report.
#
$jsonPath = Join-Path $OutputDirectory 'pci-status.json'
$textPath = Join-Path $OutputDirectory 'pci-status.txt'

$script:Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add(('PCI status of {0} at {1}' -f $script:Report.computer, $script:Report.utc))
$lines.Add('')
$lines.Add('--- summary ---')
foreach ($entry in $script:Report.summary.classes.GetEnumerator()) {
    $lines.Add(('{0,-24} {1}' -f $entry.Key, $entry.Value))
}
$lines.Add(('devices with a problem    {0}' -f $script:Report.summary.devices_with_a_problem))
$lines.Add(('devices that are not there {0}' -f $script:Report.summary.devices_that_are_not_there))
$lines.Add('')
$lines.Add('--- the devices of the bus PCI ---')
foreach ($record in $script:Report.pci) {
    $lines.Add(('{0} | {1} | class {2} | status {3} | problem {4} | {5}' -f $record.instance_id, $record.name, $record.class, $record.status, $record.problem_code, $record.bus))
    $lines.Add(('    driver {0} {1} service {2} parent {3}' -f $record.driver, $record.driver_version, $record.service, $record.parent))
}
$lines.Add('')
$lines.Add('--- the devices with a problem ---')
foreach ($record in $script:Report.problems) {
    $lines.Add(('{0} | {1} | class {2} | status {3} | problem {4} | driver {5}' -f $record.instance_id, $record.name, $record.class, $record.status, $record.problem_code, $record.driver))
}
$lines.Add('')
$lines.Add('--- the devices of the class ACPI ---')
foreach ($record in $script:Report.acpi) {
    $lines.Add(('{0} | {1} | status {2} | problem {3}' -f $record.instance_id, $record.name, $record.status, $record.problem_code))
}
$lines.Add('')
$lines.Add('--- the devices of the class I2C ---')
foreach ($record in $script:Report.i2c) {
    $lines.Add(('{0} | {1} | status {2} | problem {3} | driver {4}' -f $record.instance_id, $record.name, $record.status, $record.problem_code, $record.driver))
}
$lines.Add('')
$lines.Add('--- the registry of the bus ---')
foreach ($class in @('pci', 'acpi')) {
    $lines.Add(('[{0}]' -f $class))
    foreach ($entry in $script:Report.registry[$class]) {
        $lines.Add(('  {0}' -f $entry.instance))
        foreach ($value in $entry.values.GetEnumerator()) {
            if ($value.Key -eq 'Driver') { continue }
            $lines.Add(('      {0} = {1}' -f $value.Key, $value.Value))
        }
        foreach ($value in $entry.parameters.GetEnumerator()) {
            $lines.Add(('      [parameter] {0} = {1}' -f $value.Key, $value.Value))
        }
    }
}
$lines.Add('')
$lines.Add('--- the entries of the system log ---')
foreach ($event in $script:Report.events) {
    $lines.Add(('{0} | {1} | {2} | {3}' -f $event.utc, $event.provider, $event.id, $event.level))
    foreach ($line in ($event.message -split "`r?`n")) {
        if ($line.Trim()) { $lines.Add('    ' + $line.Trim()) }
    }
}$lines.Add('')
$lines.Add('--- the devices with a problem of pnputil ---')
foreach ($line in ($script:Report.pnputil -split "`r?`n")) {
    $lines.Add($line)
}
if ($script:Report.errors.Count -gt 0) {
    $lines.Add('')
    $lines.Add('--- the errors of the collector ---')
    foreach ($errorText in $script:Report.errors) {
        $lines.Add($errorText)
    }
}

$lines | Set-Content -LiteralPath $textPath -Encoding UTF8

Write-Report ('the report is written to {0}' -f $OutputDirectory)
Write-Report ('{0} devices, {1} of them with a problem' -f $script:Report.summary.devices, $script:Report.summary.devices_with_a_problem)

exit 0
