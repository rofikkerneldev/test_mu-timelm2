<#
.SYNOPSIS
  Shared helpers for the TimelmButtons user mode agent.

.DESCRIPTION
  The kernel driver (TimelmButtons.sys) exposes the state of the three
  physical buttons of the LG V60 through the symbolic link \\.\TimelmButtons.

  The following control codes are supported (identical to the ones in
  timelm_Drivers/src/Include/TimelmButtons.h):

    0x226000  GET_STATE     out: 48 byte TIMELM_BUTTON_STATE
    0x226004  RAW_READ      in : 16 byte TIMELM_BUTTON_RAW_REQUEST
                             out: request + data bytes
    0x22A008  SET_MAPPING   in : 80 byte TIMELM_BUTTON_MAPPING
    0x22600C  GET_MAPPING   out: 80 byte TIMELELM_BUTTON_MAPPING
    0x226010  DUMP          in : 16 byte TIMELM_BUTTON_RAW_REQUEST
                             out: request + data bytes
    0x226014  WAIT          in :  8 byte TIMELM_BUTTON_WAIT_REQUEST
                             out: 48 byte TIMELM_BUTTON_STATE

  Everything here is Windows PowerShell 5.1 compatible so that it can run on
  the phone without any extra tooling.
#>

Set-StrictMode -Version 2.0

if (-not ('TimelmButtonsNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class TimelmButtonsNative
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(
        IntPtr hDevice,
        uint dwIoControlCode,
        byte[] lpInBuffer,
        int nInBufferSize,
        byte[] lpOutBuffer,
        int nOutBufferSize,
        out uint lpBytesReturned,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool LockWorkStation();

    public const uint GENERIC_READ = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint FILE_SHARE_READ = 1;
    public const uint FILE_SHARE_WRITE = 2;
    public const uint OPEN_EXISTING = 3;
    public const uint FILE_ATTRIBUTE_NORMAL = 0x80;

    public const uint IOCTL_GET_STATE = 0x226000;
    public const uint IOCTL_RAW_READ = 0x226004;
    public const uint IOCTL_SET_MAPPING = 0x22A008;
    public const uint IOCTL_GET_MAPPING = 0x22600C;
    public const uint IOCTL_DUMP = 0x226010;
    public const uint IOCTL_WAIT = 0x226014;

    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public InputUnion u;
    }

    public static IntPtr OpenDevice()
    {
        IntPtr handle = CreateFileW(
            @"\\.\TimelmButtons",
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            IntPtr.Zero);

        if (handle == new IntPtr(-1))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "CreateFile(\\\\.\\TimelmButtons) failed");
        }

        return handle;
    }

    public static byte[] Ioctl(IntPtr device, uint code, byte[] input, int outputLength)
    {
        int inputLength = (input == null) ? 0 : input.Length;
        int size = (inputLength > outputLength) ? inputLength : outputLength;
        byte[] buffer = new byte[size];

        if (inputLength > 0)
        {
            Array.Copy(input, buffer, inputLength);
        }

        uint returned;
        if (!DeviceIoControl(device, code, buffer, inputLength, buffer, outputLength,
                             out returned, IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "DeviceIoControl(0x" + code.ToString("X8") + ") failed");
        }

        byte[] result = new byte[returned];
        Array.Copy(buffer, result, returned);
        return result;
    }

    public static void SendKey(ushort virtualKey, bool extended)
    {
        uint downFlags = extended ? KEYEVENTF_EXTENDEDKEY : 0;
        INPUT[] inputs = new INPUT[2];

        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = virtualKey;
        inputs[0].u.ki.dwFlags = downFlags;

        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = virtualKey;
        inputs[1].u.ki.dwFlags = downFlags | KEYEVENTF_KEYUP;

        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void SendShiftF10()
    {
        INPUT[] inputs = new INPUT[4];

        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].u.ki.wVk = 0x10;   // VK_SHIFT

        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].u.ki.wVk = 0x79;   // VK_F10

        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].u.ki.wVk = 0x79;
        inputs[2].u.ki.dwFlags = KEYEVENTF_KEYUP;

        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].u.ki.wVk = 0x10;
        inputs[3].u.ki.dwFlags = KEYEVENTF_KEYUP;

        SendInput(4, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
}

$script:TimelmButtonsDevicePath = '\\.\TimelmButtons'

$script:TimelmButtonNames = @{
    1 = 'Power'
    2 = 'VolumeUp'
    4 = 'VolumeDown'
}

function Get-TimelmButtonName {
    param([int]$Bit)
    if ($script:TimelmButtonNames.ContainsKey($Bit)) {
        return $script:TimelmButtonNames[$Bit]
    }
    return ('Bit{0}' -f $Bit)
}

function Open-TimelmButtons {
    <# Opens \\.\TimelmButtons and returns the native handle. #>
    return [TimelmButtonsNative]::OpenDevice()
}

function Close-TimelmButtons {
    param([IntPtr]$Handle)
    if ($Handle -ne [IntPtr]::Zero -and $Handle -ne [IntPtr](-1)) {
        [void][TimelmButtonsNative]::CloseHandle($Handle)
    }
}

function ConvertFrom-TimelmButtonState {
    <# Decodes the 48 byte TIMELM_BUTTON_STATE structure. #>
    param([byte[]]$Buffer)

    $state = [ordered]@{
        Version       = [BitConverter]::ToUInt32($Buffer, 0)
        Ready         = [BitConverter]::ToUInt32($Buffer, 4)
        Buttons       = [BitConverter]::ToUInt32($Buffer, 8)
        ChangeCounter = [BitConverter]::ToUInt32($Buffer, 12)
        PressCount    = @(
            [BitConverter]::ToUInt32($Buffer, 16),
            [BitConverter]::ToUInt32($Buffer, 20),
            [BitConverter]::ToUInt32($Buffer, 24)
        )
        HeldMillis    = @(
            [BitConverter]::ToUInt32($Buffer, 28),
            [BitConverter]::ToUInt32($Buffer, 32),
            [BitConverter]::ToUInt32($Buffer, 36)
        )
        LastEdgeMillis = [BitConverter]::ToUInt32($Buffer, 40)
        Reserved      = [BitConverter]::ToUInt32($Buffer, 44)
    }

    return [pscustomobject]$state
}

function Get-TimelmButtonState {
    param([IntPtr]$Handle)
    $buffer = [TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_GET_STATE, $null, 48)
    return ConvertFrom-TimelmButtonState $buffer
}

function Wait-TimelmButtonState {
    <# Blocks until a button edge happens or the timeout expires. #>
    param(
        [IntPtr]$Handle,
        [int]$TimeoutMillis = 250
    )

    $request = New-Object byte[] 8
    [void][BitConverter]::GetBytes([uint32]$TimeoutMillis).CopyTo($request, 0)

    $buffer = [TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_WAIT, $request, 48)
    return ConvertFrom-TimelmButtonState $buffer
}

function Get-TimelmButtonMapping {
    param([IntPtr]$Handle)
    return [TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_GET_MAPPING, $null, 80)
}

function Set-TimelmButtonMapping {
    param(
        [IntPtr]$Handle,
        [byte[]]$Mapping
    )
    if ($Mapping.Length -ne 80) {
        throw 'The mapping structure must be 80 bytes long.'
    }
    [void][TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_SET_MAPPING, $Mapping, 0)
}

function Read-TimelmPmicRegister {
    <# Reads Length (1..8) bytes from a PMIC register. #>
    param(
        [IntPtr]$Handle,
        [uint32]$Sid,
        [uint32]$Address,
        [int]$Length = 1
    )

    if ($Length -lt 1 -or $Length -gt 8) {
        throw 'Only 1..8 bytes can be read with a single request.'
    }

    $request = New-Object byte[] 16
    [void][BitConverter]::GetBytes($Sid).CopyTo($request, 0)
    [void][BitConverter]::GetBytes($Address).CopyTo($request, 4)
    [void][BitConverter]::GetBytes([uint32]$Length).CopyTo($request, 8)

    $buffer = [TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_RAW_READ, $request, 16 + $Length)
    return [byte[]]$buffer[16..($buffer.Length - 1)]
}

function ConvertTo-TimelmButtonMapping {
    <# Builds a 80 byte TIMELM_BUTTON_MAPPING structure. #>
    param(
        [int]$PowerSid = 0,
        [int]$PowerAddress = 0x810,
        [int]$PowerMask = 0x01,
        [int]$PowerPolarity = 0,
        [int]$VolumeUpSid = 0,
        [int]$VolumeUpAddress = 0xC510,
        [int]$VolumeUpMask = 0x01,
        [int]$VolumeUpPolarity = 1,
        [int]$VolumeDownSid = 0,
        [int]$VolumeDownAddress = 0x810,
        [int]$VolumeDownMask = 0x02,
        [int]$VolumeDownPolarity = 0
    )

    $mapping = New-Object byte[] 80
    [void][BitConverter]::GetBytes([uint32]1).CopyTo($mapping, 0)      # version
    [void][BitConverter]::GetBytes([uint32]3).CopyTo($mapping, 4)      # count

    $sources = @(
        @($PowerSid, $PowerAddress, $PowerMask, $PowerPolarity, 1),
        @($VolumeUpSid, $VolumeUpAddress, $VolumeUpMask, $VolumeUpPolarity, 1),
        @($VolumeDownSid, $VolumeDownAddress, $VolumeDownMask, $VolumeDownPolarity, 1)
    )

    for ($index = 0; $index -lt 3; $index++) {
        $offset = 8 + ($index * 24)
        [void][BitConverter]::GetBytes([uint32]$sources[$index][0]).CopyTo($mapping, $offset + 0)
        [void][BitConverter]::GetBytes([uint32]$sources[$index][1]).CopyTo($mapping, $offset + 4)
        [void][BitConverter]::GetBytes([uint32]$sources[$index][2]).CopyTo($mapping, $offset + 8)
        [void][BitConverter]::GetBytes([uint32]$sources[$index][3]).CopyTo($mapping, $offset + 12)
        [void][BitConverter]::GetBytes([uint32]$sources[$index][4]).CopyTo($mapping, $offset + 16)
    }

    return $mapping
}
