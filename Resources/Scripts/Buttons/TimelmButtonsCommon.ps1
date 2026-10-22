<#
.SYNOPSIS
  Shared helpers for the TimelmButtons user mode agent.

.DESCRIPTION
  The kernel driver (TimelmButtons.sys) exposes the state of the three
  physical buttons of the LG V60 through the symbolic link \\.\TimelmButtons.

  The following control codes are supported (identical to the ones in
  timelm_Drivers/src/Include/TimelmButtons.h):

    0x226000  GET_STATE     out: 56 byte TIMELM_BUTTON_STATE
    0x226004  RAW_READ      in : 16 byte TIMELM_BUTTON_RAW_REQUEST
                             out: request + data bytes
    0x22A008  SET_MAPPING   in : 152 byte TIMELM_BUTTON_MAPPING
    0x22600C  GET_MAPPING   out: 152 byte TIMELM_BUTTON_MAPPING
    0x226010  DUMP          in : 16 byte TIMELM_BUTTON_RAW_REQUEST
                             out: request + data bytes
    0x226014  WAIT          in :  8 byte TIMELM_BUTTON_WAIT_REQUEST
                             out: 56 byte TIMELM_BUTTON_STATE

  The driver of the first version used a 48 byte state and an 80 byte
  mapping.  Both are still understood, the first bytes of the structures
  did not change, so this script works with an old driver and with the
  driver that knows the HID face.

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

#
# The action ids of the mapping, they are the same in the driver
# (timelm_Drivers/src/Include/TimelmButtons.h).
#
$script:TimelmHidAction = @{
    None            = 0
    VolumeIncrement = 1
    VolumeDecrement = 2
    PowerDown       = 3
}

$script:TimelmAgentAction = @{
    None     = 0
    Tab      = 1
    Enter    = 2
    ShiftF10 = 3
    Lock     = 4
    Shutdown = 5
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
    <# Decodes the TIMELM_BUTTON_STATE structure (56 byte, 48 byte is the first version). #>
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
        HidReady      = [BitConverter]::ToUInt32($Buffer, 44)
        HidReportCount = 0
        Reserved      = 0
    }

    if ($Buffer.Length -ge 56) {
        $state.HidReportCount = [BitConverter]::ToUInt32($Buffer, 48)
        $state.Reserved = [BitConverter]::ToUInt32($Buffer, 52)
    }

    return [pscustomobject]$state
}

function Get-TimelmButtonState {
    param([IntPtr]$Handle)
    $buffer = [TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_GET_STATE, $null, 56)
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

    $buffer = [TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_WAIT, $request, 56)
    return ConvertFrom-TimelmButtonState $buffer
}

function ConvertFrom-TimelmButtonMapping {
    <# Decodes the TIMELM_BUTTON_MAPPING structure (152 byte, 80 byte is the first version). #>
    param([byte[]]$Buffer)

    $sources = @()
    $actions = @()

    for ($index = 0; $index -lt 3; $index++) {
        $offset = 8 + ($index * 24)
        $sources += [pscustomobject][ordered]@{
            Index    = $index
            Sid      = [BitConverter]::ToUInt32($Buffer, $offset + 0)
            Addr     = [BitConverter]::ToUInt32($Buffer, $offset + 4)
            Mask     = [BitConverter]::ToUInt32($Buffer, $offset + 8)
            Polarity = [BitConverter]::ToUInt32($Buffer, $offset + 12)
            Enabled  = [BitConverter]::ToUInt32($Buffer, $offset + 16)
        }
    }

    if ($Buffer.Length -ge 152) {
        for ($index = 0; $index -lt 3; $index++) {
            $offset = 80 + ($index * 24)
            $actions += [pscustomobject][ordered]@{
                Index            = $index
                HidAction        = [BitConverter]::ToUInt32($Buffer, $offset + 0)
                LongPressMillis = [BitConverter]::ToUInt32($Buffer, $offset + 4)
                AgentShortAction = [BitConverter]::ToUInt32($Buffer, $offset + 8)
                AgentLongAction  = [BitConverter]::ToUInt32($Buffer, $offset + 12)
                HidEnabled       = [BitConverter]::ToUInt32($Buffer, $offset + 16)
            }
        }
    }

    return [pscustomobject][ordered]@{
        Version = [BitConverter]::ToUInt32($Buffer, 0)
        Count   = [BitConverter]::ToUInt32($Buffer, 4)
        Source  = $sources
        Action  = $actions
    }
}

function Get-TimelmButtonMapping {
    param([IntPtr]$Handle)
    $buffer = [TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_GET_MAPPING, $null, 152)
    return ConvertFrom-TimelmButtonMapping $buffer
}

function Set-TimelmButtonMapping {
    param(
        [IntPtr]$Handle,
        [byte[]]$Mapping
    )
    if ($Mapping.Length -ne 152 -and $Mapping.Length -ne 80) {
        throw 'The mapping structure must be 152 bytes long (80 bytes for the first version).'
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
    <#
      Builds a 152 byte TIMELM_BUTTON_MAPPING structure.

      The mode decides who reacts to a short press:

        Agent  the agent answers with TAB, ENTER and the lock (the default)
        Hid    the driver reports a native volume key, the agent only
               answers a long press and the short press of the power key
        Both   both of them react, only useful to see the two paths at once

      The short press of the power key always belongs to the agent, Windows
      has no native lock and would show its power menu instead.
    #>
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
        [int]$VolumeDownPolarity = 0,
        [ValidateSet('Agent', 'Hid', 'Both')]
        [string]$Mode = 'Agent',
        [int]$PowerLongPressMillis = 1500,
        [int]$VolumeDownLongPressMillis = 800
    )

    $mapping = New-Object byte[] 152
    [void][BitConverter]::GetBytes([uint32]2).CopyTo($mapping, 0)      # version
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

    #
    # The actions of the three buttons: power, volume up, volume down.
    #
    $actions = @(
        @($script:TimelmHidAction.PowerDown, $PowerLongPressMillis, $script:TimelmAgentAction.Lock, $script:TimelmAgentAction.Shutdown),
        @($script:TimelmHidAction.VolumeIncrement, 0, $script:TimelmAgentAction.Tab, $script:TimelmAgentAction.None),
        @($script:TimelmHidAction.VolumeDecrement, $VolumeDownLongPressMillis, $script:TimelmAgentAction.Enter, $script:TimelmAgentAction.ShiftF10)
    )

    #
    # The mode decides who answers a short press.  The volume keys have a
    # native counterpart in Windows, so the HID face of the driver takes them
    # over in the mode Hid.  The power key has no native lock, Windows would
    # show its power menu instead, so the agent keeps the short press of the
    # power key in every mode.  The mode Both shows both paths at once, it is
    # only good for a test.
    #
    # A long press always belongs to the agent, only the agent knows the long
    # actions.
    #
    $useHid = ($Mode -eq 'Hid' -or $Mode -eq 'Both')
    $useAgent = ($Mode -eq 'Agent' -or $Mode -eq 'Both')

    for ($index = 0; $index -lt 3; $index++) {
        $offset = 80 + ($index * 24)

        $hidAction = 0
        $hidEnabled = 0
        $agentShort = 0
        $agentLong = $actions[$index][3]

        if ($useHid) {
            $hidAction = $actions[$index][0]
            # In the mode Hid the power key keeps the agent, Windows has no
            # native lock.  The mode Both lets the HID face show its report
            # of the power key as well.
            if (($index -ne 0) -or ($Mode -eq 'Both')) { $hidEnabled = 1 }
        }
        if ($useAgent) {
            $agentShort = $actions[$index][2]
        }
        if (($Mode -eq 'Hid') -and ($index -eq 0)) {
            $agentShort = $actions[0][2]
        }

        [void][BitConverter]::GetBytes([uint32]$hidAction).CopyTo($mapping, $offset + 0)
        [void][BitConverter]::GetBytes([uint32]$actions[$index][1]).CopyTo($mapping, $offset + 4)
        [void][BitConverter]::GetBytes([uint32]$agentShort).CopyTo($mapping, $offset + 8)
        [void][BitConverter]::GetBytes([uint32]$agentLong).CopyTo($mapping, $offset + 12)
        [void][BitConverter]::GetBytes([uint32]$hidEnabled).CopyTo($mapping, $offset + 16)
    }

    return $mapping
}
