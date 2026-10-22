<#
.SYNOPSIS
  Brute force discovery of the PMIC registers that carry the LG V60 buttons.

.DESCRIPTION
  The driver exposes raw PMIC register reads, so the real register layout can
  be verified without rebuilding the driver:

      1. the window is sampled while no button is pressed (idle baseline)
      2. the window is sampled again while one button is held down
      3. every byte that changed is reported with its address and the bits
         that differ

  The result is used to build the mapping that is written back with
  IOCTL_TIMELM_BUTTONS_SET_MAPPING.

  The default window covers the two blocks that are relevant for the
  buttons of the LG V60:

      0x0800 - 0x08FF   PON (power on) block of the PM8150
      0xC000 - 0xCAFF   PMIC GPIO block of the PM8150

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Discover-TimelmButtons.ps1 -Button VolumeUp
#>
[CmdletBinding()]
param(
    [int]$Sid = 0,
    [int]$Start = 0x800,
    [int]$End = 0x8FF,
    [int]$Button = 0,
    [int]$IdleSeconds = 3,
    [int]$PressSeconds = 6,
    [int]$SampleIntervalMillis = 40,
    [string]$LogPath = (Join-Path $env:ProgramData 'Timelm\button-discovery.log')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TimelmButtonsCommon.ps1')

function Write-DiscoveryLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    try {
        $directory = Split-Path -Parent $LogPath
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
    }
    Write-Host $line
}

function Read-TimelmPmicWindow {
    <# Reads [Start..End] and returns a byte array. #>
    param(
        [IntPtr]$Handle,
        [int]$First,
        [int]$Last
    )

    $size = $Last - $First + 1
    $window = New-Object byte[] $size

    for ($offset = 0; $offset -lt $size; $offset += 8) {
        $chunk = [Math]::Min(8, $size - $offset)
        $data = Read-TimelmPmicRegister -Handle $Handle -Sid $Sid -Address ($First + $offset) -Length $chunk
        for ($i = 0; $i -lt $chunk; $i++) {
            $window[$offset + $i] = $data[$i]
        }
    }

    return $window
}

$handle = [IntPtr]::Zero
try {
    $handle = Open-TimelmButtons
    Write-DiscoveryLog ('device opened, window 0x{0:X4}..0x{1:X4} on sid {2}' -f $Start, $End, $Sid)

    $state = Get-TimelmButtonState -Handle $handle
    if ($state.Ready -eq 0) {
        Write-DiscoveryLog 'warning: the driver is not connected to the PMIC yet'
    }

    Write-Host 'Keep every button released for the idle baseline ...'
    $baseline = Read-TimelmPmicWindow -Handle $handle -First $Start -Last $End
    $idleUntil = (Get-Date).AddSeconds($IdleSeconds)
    while ((Get-Date) -lt $idleUntil) {
        Start-Sleep -Milliseconds $SampleIntervalMillis
        $baseline = Read-TimelmPmicWindow -Handle $handle -First $Start -Last $End
    }
    Write-DiscoveryLog 'idle baseline captured'

    if ($Button -ne 0) {
        Write-Host ('Now press and HOLD the {0} button ...' -f (Get-TimelmButtonName $Button))
    } else {
        Write-Host 'Now press and HOLD one button ...'
    }

    $changed = @{}
    $pressUntil = (Get-Date).AddSeconds($PressSeconds)
    while ((Get-Date) -lt $pressUntil) {
        Start-Sleep -Milliseconds $SampleIntervalMillis
        $current = Read-TimelmPmicWindow -Handle $handle -First $Start -Last $End
        for ($i = 0; $i -lt $current.Length; $i++) {
            if ($current[$i] -ne $baseline[$i]) {
                $address = $Start + $i
                if (-not $changed.ContainsKey($address)) {
                    $changed[$address] = $true
                    $diff = $current[$i] -bxor $baseline[$i]
                    Write-DiscoveryLog ('changed sid {0} addr 0x{1:X4} idle 0x{2:X2} now 0x{3:X2} diff 0x{4:X2}' -f `
                            $Sid, $address, $baseline[$i], $current[$i], $diff)
                }
            }
        }
    }

    if ($changed.Count -eq 0) {
        Write-DiscoveryLog 'no register changed inside the window'
        exit 2
    }

    Write-Host ''
    Write-Host 'Candidate registers:'
    foreach ($address in ($changed.Keys | Sort-Object)) {
        Write-Host ('  0x{0:X4}' -f $address)
    }
}
finally {
    Close-TimelmButtons -Handle $handle
}
