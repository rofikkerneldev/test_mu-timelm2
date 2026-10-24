<#
.SYNOPSIS
  Stages the TimelmButtons trial bundle on the LG V60 (timelm) phone.

.DESCRIPTION
  PC side staging only.  The script copies the button driver package and the
  trial scripts from a verified CI artifact onto the Windows partition of the
  identified phone and writes a receipt with the hashes of every staged file.

  The script never touches the ESP, the BCD or the boot order, the trial is a
  Windows side trial only.  The staged bundle is not armed automatically, the
  trial is started by the user on the phone.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Stage-TimelmButtonsTrial.ps1 `
      -Artifact C:\artifacts\timelm-native-buttons -Output C:\receipts\buttons

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Stage-TimelmButtonsTrial.ps1 `
      -Artifact C:\artifacts\timelm-native-buttons -Output C:\receipts\buttons `
      -ButtonMode Hid -Arm

.EXAMPLE
  # a second trial, the bundle and the receipts of the first one are
  # archived on the PC before they are removed from the phone
  powershell -ExecutionPolicy Bypass -File Stage-TimelmButtonsTrial.ps1 `
      -Artifact C:\artifacts\timelm-native-buttons -Output C:\receipts\buttons `
      -ButtonMode Agent -Replace
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Artifact,
    [Parameter(Mandatory = $true)][string]$Output,
    [ValidateSet('Agent', 'Hid', 'Both')]
    [string]$ButtonMode = 'Agent',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left', 'AltTab')]
    [string]$AssistAction = 'Enter',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left', 'AltTab')]
    [string]$AssistLongAction = 'Tab',
    [int]$AssistLongPressMillis = 800,
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left', 'AltTab')]
    [string]$PowerAction = 'Tab',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left', 'AltTab')]
    [string]$PowerLongAction = 'AltTab',
    [int]$PowerLongPressMillis = 1500,
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left', 'AltTab')]
    [string]$VolumeUpAction = 'Up',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left', 'AltTab')]
    [string]$VolumeUpLongAction = 'Right',
    [int]$VolumeUpLongPressMillis = 800,
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left', 'AltTab')]
    [string]$VolumeDownAction = 'Down',
    [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu', 'DisplayToggle', 'Unlock', 'Close', 'Up', 'Right', 'Down', 'Left', 'AltTab')]
    [string]$VolumeDownLongAction = 'Left',
    [int]$VolumeDownLongPressMillis = 800,
    [string]$AssistTarget = 'notepad.exe',
    [int]$Seconds = 240,
    [string]$UserProfile = 'Administrator',
    [switch]$Arm,
    [switch]$ArmTask,
    [switch]$Replace
)

$ErrorActionPreference = 'Stop'

if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw 'Run staging on the x64 PC, not on the phone' }

$modified = $false

function Write-Flushed([string]$Path, [byte[]]$Data) {
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $stream.Write($Data, 0, $Data.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Copy-Verified([string]$Source, [string]$Destination) {
    $bytes = [IO.File]::ReadAllBytes($Source)
    Write-Flushed $Destination $bytes
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $hash) {
        throw "Copy verification failed: $Destination"
    }
    return $hash
}

function Get-Sha256Text {
    <#
      The hash of a text that the phone writes with
      [IO.File]::WriteAllText, that is UTF-8 without a byte order mark.
    #>
    param([string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Remove-TimelmTaskFile([string]$Path) {
    <#
      Removes a task file of a previous trial.  The file was written by the
      build PC, so the build PC is the owner of it and may take the rights
      that it needs for the removal.  The volume of the phone answers the
      first removal with a denial now and then, and the folder of the tasks
      of the phone does not always allow the removal at all.

      A task file that stays is not a problem: the staging of the next trial
      writes its own task over the old one, and the trial removes the task
      at the end of the attempt.
    #>
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            return $true
        } catch {
            & takeown.exe /f $Path 2>&1 | Out-Null
            & icacls.exe $Path /setowner $env:USERNAME 2>&1 | Out-Null
            & icacls.exe $Path /grant ('{0}:F' -f $env:USERNAME) 2>&1 | Out-Null
            Start-Sleep -Milliseconds 700
        }
    }

    return $false
}

function Get-TimelmTaskXml {
    <#
      The task of the phone that starts the trial at the logon of the
      administrator.

      The Startup folder of the phone belongs to its own administrators, and
      Windows of the phone applied its own rights to the ProgramData, so the
      build PC cannot write the Startup entry.  The folder of the task
      scheduler can be written, the scheduler reads the tasks of that folder
      when its service starts, so a task that is put there runs at the next
      boot.

      The task names the built-in administrator of the phone by its security
      identifier.  The identifier is the one that the phone wrote into its own
      log of the first desktop, the machine of the phone was installed more
      than once and the identifier of an earlier installation does not match.

      The task is started when it may be started as well: a trigger whose
      moment has passed while the scheduler was still loading the task starts
      the task anyway, otherwise a task that is read after the logon of the
      phone would never run.
    #>
    param(
        [string]$Command,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$UserSid = 'S-1-5-21-2900457808-1833740068-2038273949-500',
        [string]$TaskName = 'TimelmButtonsTrial'
    )

    function Escape-Xml([string]$Text) {
        return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    }

    $lines = @(
        '<?xml version="1.0" encoding="UTF-16"?>'
        '<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
        '  <RegistrationInfo>'
        '    <Author>timelm</Author>'
        '    <Description>TimelmButtons trial</Description>'
        ('    <URI>\{0}</URI>' -f $TaskName)
        '  </RegistrationInfo>'
        '  <Triggers>'
        '    <BootTrigger>'
        '      <Enabled>true</Enabled>'
        '      <Delay>PT60S</Delay>'
        '      <StartBoundary>2026-01-01T00:00:00</StartBoundary>'
        '    </BootTrigger>'
        '    <LogonTrigger>'
        '      <Enabled>true</Enabled>'
        ('      <UserId>{0}</UserId>' -f $UserSid)
        '    </LogonTrigger>'
        '  </Triggers>'
        '  <Principals>'
        '    <Principal id="Author">'
        ('      <UserId>{0}</UserId>' -f $UserSid)
        '      <LogonType>InteractiveToken</LogonType>'
        '      <RunLevel>HighestAvailable</RunLevel>'
        '    </Principal>'
        '  </Principals>'
        '  <Settings>'
        '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
        '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
        '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
        '    <AllowHardTerminate>true</AllowHardTerminate>'
        '    <StartWhenAvailable>true</StartWhenAvailable>'
        '    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>'
        '    <IdleSettings>'
        '      <StopOnIdleEnd>false</StopOnIdleEnd>'
        '      <RestartOnIdle>false</RestartOnIdle>'
        '    </IdleSettings>'
        '    <AllowStartOnDemand>true</AllowStartOnDemand>'
        '    <Enabled>true</Enabled>'
        '    <Hidden>false</Hidden>'
        '    <RunOnlyIfIdle>false</RunOnlyIfIdle>'
        '    <WakeToRun>false</WakeToRun>'
        '    <ExecutionTimeLimit>PT15M</ExecutionTimeLimit>'
        '    <Priority>7</Priority>'
        '  </Settings>'
        '  <Actions Context="Author">'
        '    <Exec>'
        ('      <Command>{0}</Command>' -f (Escape-Xml $Command))
        ('      <Arguments>{0}</Arguments>' -f (Escape-Xml $Arguments))
        ('      <WorkingDirectory>{0}</WorkingDirectory>' -f (Escape-Xml $WorkingDirectory))
        '    </Exec>'
        '  </Actions>'
        '</Task>'
    )

    return ($lines -join "`r`n")
}

try {
    if (-not (Test-Path -LiteralPath $Output -PathType Container)) { throw 'Precreate the PC receipt directory' }
    $receiptRoot = (Get-Item -LiteralPath $Output).FullName
    $artifactRoot = (Get-Item -LiteralPath $Artifact).FullName

    $package = Join-Path $artifactRoot 'Buttons'
    if (-not (Test-Path -LiteralPath $package -PathType Container)) {
        throw 'The artifact does not contain the Buttons package'
    }

    $manifestPath = Join-Path $artifactRoot 'sha256.json'
    $sourcePath = Join-Path $artifactRoot 'source.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'The artifact has no sha256.json' }
    if (-not (Test-Path -LiteralPath $sourcePath)) { throw 'The artifact has no source.json' }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $provenance = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
    if ($provenance.architecture -ne 'ARM64') { throw 'The artifact is not an ARM64 build' }
    if ($provenance.commit -notmatch '^[0-9a-f]{40}$') { throw 'The artifact has no source revision' }

    foreach ($file in $manifest) {
        $path = Join-Path $artifactRoot $file.path
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing artifact file: $($file.path)" }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $file.sha256.ToLowerInvariant()) { throw "Artifact hash mismatch: $($file.path)" }
    }

    $sys = Join-Path $package 'TimelmButtons.sys'
    $inf = Join-Path $package 'TimelmButtons.inf'
    if (-not (Test-Path -LiteralPath $sys) -or -not (Test-Path -LiteralPath $inf)) {
        throw 'The Buttons package is incomplete'
    }
    $bytes = [IO.File]::ReadAllBytes($sys)
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0xaa64) {
        throw 'The button driver is not an ARM64 image'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $sys
    if (-not $signature.SignerCertificate) { throw 'The button driver is not signed' }

    $disks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.SerialNumber -and $_.SerialNumber.Trim() -eq '8509C01F' })
    if ($disks.Count -ne 1 -or $disks[0].Size -ne 126374379520 -or $disks[0].IsBoot -or $disks[0].IsSystem) {
        throw 'V60 USB disk mismatch'
    }
    $win = Get-Partition -DiskNumber $disks[0].Number -PartitionNumber 30
    if ($win.Offset -ne 62719688704 -or $win.Size -ne 42949672960 -or -not $win.DriveLetter) {
        throw 'V60 partition geometry mismatch'
    }
    $winRoot = [string]$win.DriveLetter + ':\'
    $volume = Get-Volume -DriveLetter $win.DriveLetter
    if ($volume.FileSystem -ne 'NTFS') { throw 'Wrong target filesystem' }

    foreach ($pcPath in @($receiptRoot, $artifactRoot)) {
        if ($pcPath -notmatch '^[A-Za-z]:\\') { throw 'Use an absolute PC drive-letter path for artifact and receipts' }
        $pcPartition = Get-Partition -DriveLetter $pcPath.Substring(0, 1)
        if ($pcPartition.DiskNumber -eq $disks[0].Number) { throw 'Artifact and receipt storage must not use any phone partition' }
    }

    $marker = Join-Path $winRoot 'TimelmTools\OobeHelper\timelm-device.marker'
    if (-not (Test-Path -LiteralPath $marker)) { throw 'Wrong installed Windows marker' }
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne 'LG-V60-timelm-8509C01F') { throw 'Wrong installed Windows marker' }

    $bundle = Join-Path $winRoot 'TimelmTools\TimelmButtonsTrial'
    $logDir = Join-Path $winRoot 'TimelmLogs\TimelmButtonsTrial'
    $startup = Join-Path $winRoot 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Timelm-buttons.cmd'
    $startupUser = Join-Path $winRoot ('Users\{0}\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Timelm-buttons.cmd' -f $UserProfile)
    $taskFile = Join-Path $winRoot 'Windows\System32\Tasks\TimelmButtonsTrial'

    #
    # A trial leaves its bundle, its receipts and possibly its startup entry
    # on the phone.  A second trial needs a clean phone, but the receipts of
    # the first one are evidence and are archived on the PC before they are
    # removed.
    #
    $archived = @()
    if ((Test-Path -LiteralPath $bundle) -or (Test-Path -LiteralPath $logDir)) {
        if (-not $Replace) {
            throw 'A previous button trial is still on the phone, use -Replace to archive it'
        }

        if (Test-Path -LiteralPath $logDir) {
            $archive = Join-Path $receiptRoot 'previous-trial-logs'
            if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Recurse -Force }
            Copy-Item -LiteralPath $logDir -Destination $archive -Recurse -Force
            $archived += 'TimelmLogs\TimelmButtonsTrial'
            Remove-Item -LiteralPath $logDir -Recurse -Force
        }
        if (Test-Path -LiteralPath $bundle) {
            Remove-Item -LiteralPath $bundle -Recurse -Force
            $archived += 'TimelmTools\TimelmButtonsTrial'
        }
        if (Test-Path -LiteralPath $startup) {
            Remove-Item -LiteralPath $startup -Force
            $archived += 'Startup\Timelm-buttons.cmd'
        }
        if (Test-Path -LiteralPath $startupUser) {
            Remove-Item -LiteralPath $startupUser -Force
            $archived += 'Startup\Timelm-buttons.cmd (user profile)'
        }
        if (Test-Path -LiteralPath $taskFile) {
            if (Remove-TimelmTaskFile $taskFile) {
                $archived += 'Tasks\TimelmButtonsTrial'
            } else {
                $archived += 'Tasks\TimelmButtonsTrial (the new task is written over it)'
            }
        }
        $modified = $true
    }

    $scripts = @(
        @{ source = (Join-Path $PSScriptRoot 'Run-TimelmButtonsTrial.ps1'); relative = 'Run-TimelmButtonsTrial.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'Start-TimelmButtonsTrial.ps1'); relative = 'Start-TimelmButtonsTrial.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'TimelmButtonAgent.ps1'); relative = 'TimelmButtonAgent.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1'); relative = 'TimelmButtonsCommon.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'Set-TimelmButtonMode.ps1'); relative = 'Set-TimelmButtonMode.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'Install-TimelmButtonAgent.ps1'); relative = 'Install-TimelmButtonAgent.ps1' },
        @{ source = (Join-Path $PSScriptRoot 'Collect-TimelmPciStatus.ps1'); relative = 'Collect-TimelmPciStatus.ps1' },
        @{ source = $manifestPath; relative = 'sha256.json' },
        @{ source = $sourcePath; relative = 'source.json' }
    )
    foreach ($file in Get-ChildItem -LiteralPath $package -File) {
        $scripts += @{ source = $file.FullName; relative = ('Drivers/Buttons/' + $file.Name) }
    }

    $null = New-Item -ItemType Directory -Path $bundle
    $modified = $true

    #
    # The launcher of the trial carries the button mode, the mode of the
    # mapping is written by the trial before the agent starts.
    #
    $cmdSource = Join-Path $PSScriptRoot 'Timelm-buttons.cmd'
    $cmdText = [IO.File]::ReadAllText($cmdSource)
    if ($cmdText -notmatch '-ButtonMode\s+(Agent|Hid|Both)') { throw 'The trial launcher has no button mode' }
    $cmdText = $cmdText -replace '-ButtonMode\s+(Agent|Hid|Both)', ('-ButtonMode ' + $ButtonMode)
    if ($cmdText -notmatch '-AssistAction\s+\w+') { throw 'The trial launcher has no assist action' }
    $cmdText = $cmdText -replace '-AssistAction\s+\w+', ('-AssistAction ' + $AssistAction)
    if ($cmdText -notmatch '-AssistTarget\s+"[^"]*"') { throw 'The trial launcher has no assist target' }
    $cmdText = $cmdText -replace '-AssistTarget\s+"[^"]*"', ('-AssistTarget "{0}"' -f $AssistTarget)
    if ($cmdText -notmatch '-Seconds\s+\d+') { throw 'The trial launcher has no time' }
    $cmdText = $cmdText -replace '-Seconds\s+\d+', ('-Seconds {0}' -f $Seconds)

    #
    # The mapping of the buttons is written into the launcher as well, so
    # that the receipt of the attempt shows the mapping that was armed and
    # not only the one that the trial wrote into the driver.
    #
    $mapping = [ordered]@{
        'PowerAction' = $PowerAction
        'PowerLongAction' = $PowerLongAction
        'VolumeUpAction' = $VolumeUpAction
        'VolumeUpLongAction' = $VolumeUpLongAction
        'VolumeDownAction' = $VolumeDownAction
        'VolumeDownLongAction' = $VolumeDownLongAction
        'AssistLongAction' = $AssistLongAction
    }
    foreach ($entry in $mapping.GetEnumerator()) {
        if ($cmdText -notmatch ('-{0}\s+\w+' -f $entry.Key)) { throw ('The trial launcher has no {0}' -f $entry.Key) }
        $cmdText = $cmdText -replace ('-{0}\s+\w+' -f $entry.Key), ('-{0} {1}' -f $entry.Key, $entry.Value)
    }
    $millis = [ordered]@{
        'PowerLongPressMillis' = $PowerLongPressMillis
        'VolumeUpLongPressMillis' = $VolumeUpLongPressMillis
        'VolumeDownLongPressMillis' = $VolumeDownLongPressMillis
        'AssistLongPressMillis' = $AssistLongPressMillis
    }
    foreach ($entry in $millis.GetEnumerator()) {
        if ($cmdText -notmatch ('-{0}\s+\d+' -f $entry.Key)) { throw ('The trial launcher has no {0}' -f $entry.Key) }
        $cmdText = $cmdText -replace ('-{0}\s+\d+' -f $entry.Key), ('-{0} {1}' -f $entry.Key, $entry.Value)
    }
    $cmdPath = Join-Path $bundle 'Timelm-buttons.cmd'
    Write-Flushed $cmdPath ([Text.Encoding]::ASCII.GetBytes($cmdText))

    #
    # The target of the assist key is a text file in the ProgramData of the
    # phone.  The trial writes it, the build PC has no write right on that
    # folder, the volume of the phone belongs to its own administrators.
    #
    # The reference time of the build PC.  The RTC of the phone runs hours
    # behind, the trial corrects the clock before it writes any receipt.
    $hostUtc = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $bundle 'host-utc.txt'), $hostUtc)

    $hashes = foreach ($file in $scripts) {
        $destination = Join-Path $bundle ($file.relative -replace '/', '\')
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
        $hash = Copy-Verified $file.source $destination
        [ordered]@{ path = $file.relative; sha256 = $hash }
    }
    $hashes += [ordered]@{ path = 'host-utc.txt'; sha256 = (Get-FileHash -LiteralPath (Join-Path $bundle 'host-utc.txt') -Algorithm SHA256).Hash }
    $hashes += [ordered]@{ path = 'Timelm-buttons.cmd'; sha256 = (Get-FileHash -LiteralPath $cmdPath -Algorithm SHA256).Hash }
    $hashes += [ordered]@{ path = 'ProgramData/Timelm/assist-target.txt'; sha256 = (Get-Sha256Text -Text $AssistTarget) }

    #
    # The manifest of the bundle names the files with the path that they
    # have inside the bundle, so that the bundle on the phone can be
    # checked on its own without the artifact of the CI.
    #
    $bundleManifest = Join-Path $bundle 'bundle-sha256.json'
    $hashes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bundleManifest -Encoding UTF8

    $staged = [ordered]@{
        phase = 'staged'
        utc = [DateTime]::UtcNow.ToString('o')
        serial = '8509C01F'
        disk = $disks[0].Number
        bundle = $bundle
        driver_commit = $provenance.commit
        driver_architecture = $provenance.architecture
        driver_configuration = $provenance.configuration
        driver_sha256 = (Get-FileHash -LiteralPath $sys -Algorithm SHA256).Hash
        inf_sha256 = (Get-FileHash -LiteralPath $inf -Algorithm SHA256).Hash
        button_mode = $ButtonMode
        assist_action = $AssistAction
        assist_target = $AssistTarget
        mapping = [ordered]@{
            power = [ordered]@{ short = $PowerAction; long = $PowerLongAction; long_press_ms = $PowerLongPressMillis }
            volume_up = [ordered]@{ short = $VolumeUpAction; long = $VolumeUpLongAction; long_press_ms = $VolumeUpLongPressMillis }
            volume_down = [ordered]@{ short = $VolumeDownAction; long = $VolumeDownLongAction; long_press_ms = $VolumeDownLongPressMillis }
            assist = [ordered]@{ short = $AssistAction; long = $AssistLongAction; long_press_ms = $AssistLongPressMillis }
        }
        seconds = $Seconds
        archived = $archived
        files = $hashes
        armed = $Arm.IsPresent -or $ArmTask.IsPresent
        manual_start = 'powershell.exe -ExecutionPolicy Bypass -File C:\TimelmTools\TimelmButtonsTrial\Start-TimelmButtonsTrial.ps1 -Seconds {0} -ButtonMode {1} -AssistAction {2} -AssistTarget "{3}"' -f $Seconds, $ButtonMode, $AssistAction, $AssistTarget
        esp_touched = $false
        bcd_changed = $false
        boot_order_changed = $false
    }
    $staged | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')

    if ($Arm) {
        #
        # The Startup entry of the phone starts the trial at the logon.  The
        # common folder of the Startup belongs to the administrators of the
        # phone since Windows applied its own rights to the ProgramData, so
        # the folder of the user of the phone is used when the common one
        # cannot be written.  Both are read by Windows at the logon of the
        # user, without any service of the phone.
        #
        $cmdBytes = [IO.File]::ReadAllBytes((Join-Path $bundle 'Timelm-buttons.cmd'))
        $cmdHash = (Get-FileHash -LiteralPath (Join-Path $bundle 'Timelm-buttons.cmd') -Algorithm SHA256).Hash

        $candidates = @(
            [pscustomobject]@{
                kind = 'startup-entry'
                path = (Join-Path $winRoot 'ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Timelm-buttons.cmd')
            },
            [pscustomobject]@{
                kind = 'startup-entry-user'
                path = (Join-Path $winRoot ('Users\{0}\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\Timelm-buttons.cmd' -f $UserProfile))
            }
        )

        $armed = $false
        $failures = @()
        foreach ($candidate in $candidates) {
            try {
                $directory = Split-Path -Parent $candidate.path
                if (-not (Test-Path -LiteralPath $directory)) {
                    New-Item -ItemType Directory -Path $directory -Force | Out-Null
                }

                $stream = New-Object IO.FileStream($candidate.path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
                try {
                    $stream.Write($cmdBytes, 0, $cmdBytes.Length)
                    $stream.Flush($true)
                } finally {
                    $stream.Dispose()
                }

                if ((Get-FileHash -LiteralPath $candidate.path -Algorithm SHA256).Hash -ne $cmdHash) {
                    throw 'Startup readback failed'
                }

                $staged.armed = $true
                $staged.arm_method = $candidate.kind
                $staged.startup_path = $candidate.path
                $staged.startup_sha256 = $cmdHash
                $armed = $true
                break
            } catch {
                $failures += ('{0}: {1}' -f $candidate.kind, $_.Exception.Message)
            }
        }

        if (-not $armed) {
            if ($ArmTask.IsPresent) {
                #
                # The task of the scheduler is the second way to start the
                # trial, a Startup entry that cannot be written is only a
                # note in the receipt then.
                #
                $staged.startup_failures = $failures
                $staged | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')
                Write-Warning ("no Startup entry of the phone could be written ({0}), the task of the scheduler arms the trial" -f ($failures -join '; '))
            } else {
                #
                # The Startup folder of the phone belongs to the
                # administrators of the phone.  A build PC that runs with a
                # filtered token does not belong to that group, and the
                # filter of the token turns the right of the group into a
                # denial.  The staging therefore has to run with the full
                # token of an administrator of the build PC.
                #
                throw ("no Startup entry of the phone could be written ({0}). The Startup folder of the phone belongs to the administrators of the phone: run the staging with the full token of an administrator of the build PC, or start the trial by hand" -f ($failures -join '; '))
            }
        } else {
            $staged | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')
        }
    }

    if ($ArmTask) {
        #
        # The task of the task scheduler is the way to start the trial after
        # the next boot, the Startup folder of the phone cannot be written
        # from the build PC any more.  The file is written in the format of
        # the task scheduler, UTF-16 with a byte order mark.
        #
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "C:\TimelmTools\TimelmButtonsTrial\Start-TimelmButtonsTrial.ps1" -Seconds {0} -ButtonMode {1} -AssistAction {2} -AssistTarget "{3}"' -f $Seconds, $ButtonMode, $AssistAction, $AssistTarget
        $xml = Get-TimelmTaskXml `
            -Command 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -Arguments $arguments `
            -WorkingDirectory 'C:\TimelmTools\TimelmButtonsTrial'
        $bytes = [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes($xml)
        Write-Flushed $taskFile $bytes

        $readBack = [IO.File]::ReadAllBytes($taskFile)
        if ($readBack.Length -ne $bytes.Length) { throw 'The task of the phone did not read back' }
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($readBack[$i] -ne $bytes[$i]) { throw 'The task of the phone did not read back' }
        }

        $staged.armed = $true
        if ($staged.arm_method -eq 'startup-entry' -or $staged.arm_method -eq 'startup-entry-user') {
            # Both ways to start the trial are armed, the Startup entry of the
            # phone and the task of the scheduler.  The receipt names both of
            # them, so that the next boot is covered by two of them.
            $staged.arm_method = '{0}+scheduled-task' -f $staged.arm_method
        } else {
            $staged.arm_method = 'scheduled-task'
        }
        $staged.task_path = 'C:\Windows\System32\Tasks\TimelmButtonsTrial'
        $staged.task_sha256 = (Get-FileHash -LiteralPath $taskFile -Algorithm SHA256).Hash
        $staged | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')
    }

    Write-Host ("Button trial bundle staged on {0}" -f $bundle)
}
catch {
    $failure = $_.Exception.Message
    if ($modified -and (Test-Path -LiteralPath $bundle)) {
        Remove-Item -LiteralPath $bundle -Recurse -Force -ErrorAction SilentlyContinue
    }
    [ordered]@{ phase = 'failed'; error = $failure; utc = [DateTime]::UtcNow.ToString('o') } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $receiptRoot 'stage-status.json')
    throw
}
