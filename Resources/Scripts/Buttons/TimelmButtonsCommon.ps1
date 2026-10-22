<#
.SYNOPSIS
  Shared helpers for the TimelmButtons user mode agent.

.DESCRIPTION
  The kernel driver (TimelmButtons.sys) exposes the state of the three
  physical buttons of the LG V60 through the symbolic link \\.\TimelmButtons.

  The following control codes are supported (identical to the ones in
  timelm_Drivers/src/Include/TimelmButtons.h):

    0x226000  GET_STATE     out: 64 byte TIMELM_BUTTON_STATE
    0x226004  RAW_READ      in : 16 byte TIMELM_BUTTON_RAW_REQUEST
                             out: request + data bytes
    0x22A008  SET_MAPPING   in : 200 byte TIMELM_BUTTON_MAPPING
    0x22600C  GET_MAPPING   out: 200 byte TIMELM_BUTTON_MAPPING
    0x226010  DUMP          in : 16 byte TIMELM_BUTTON_RAW_REQUEST
                             out: request + data bytes
    0x226014  WAIT          in :  8 byte TIMELM_BUTTON_WAIT_REQUEST
                             out: 64 byte TIMELM_BUTTON_STATE

  The driver of the first version used a 48 byte state and an 80 byte
  mapping, the second version used a 56 byte state and a 152 byte mapping.
  All of them are still understood.  The layout of the structures is append
  only, so the first bytes of the current version carry the same values as
  the older versions.  This script reads the length of the answer and the
  version field, so it works with an old driver and with the current one.

  The current version knows a fourth button, the assist key of the phone.
  It is read from PMIC gpio1 (0xC010 bit 0, active low).

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

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetUserObjectInformation(
        IntPtr hObj,
        int nIndex,
        byte[] pvInfo,
        uint nLength,
        out uint lpdwLengthNeeded);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool CloseDesktop(IntPtr hDesktop);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    public const uint GENERIC_READ = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint FILE_SHARE_READ = 1;
    public const uint FILE_SHARE_WRITE = 2;
    public const uint OPEN_EXISTING = 3;
    public const uint FILE_ATTRIBUTE_NORMAL = 0x80;

    //
    // SetThreadExecutionState
    //
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;
    public const uint ES_CONTINUOUS = 0x80000000;

    //
    // GetUserObjectInformation
    //
    public const int UOI_NAME = 2;
    public const uint DESKTOP_SWITCHDESKTOP = 0x0100;

    //
    // SendMessage
    //
    public const uint WM_SYSCOMMAND = 0x0112;
    public const uint SC_MONITORPOWER = 0xF170;
    public static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);

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

    //
    // Turns the display on again and resets the idle timers of the system.
    // The call is made without ES_CONTINUOUS, so the request ends with the
    // thread of the agent.
    //
    public static uint WakeDisplay()
    {
        uint previous = SetThreadExecutionState(ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);

        //
        // The broadcast switches the monitor on, it also works while the
        // session is locked.
        //
        SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, new IntPtr((int)SC_MONITORPOWER), new IntPtr(-1));

        return previous;
    }

    //
    // A small movement of the mouse.  It wakes the system when it is in the
    // modern standby state, where the timer of the agent does not run any
    // more.
    //
    public static uint NudgeMouse()
    {
        INPUT[] inputs = new INPUT[1];

        inputs[0].type = 0;             // INPUT_MOUSE
        inputs[0].u.mi.dx = 1;
        inputs[0].u.mi.dy = 0;
        inputs[0].u.mi.dwFlags = 0x0001; // MOUSEEVENTF_MOVE

        return SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    //
    // The name of the desktop that has the input focus.  While the
    // workstation is locked it is the "Winlogon" desktop of the secure
    // desktop, otherwise it is the "Default" desktop of the session.
    // The name is null when the desktop cannot be opened.
    //
    public static string GetInputDesktopName()
    {
        IntPtr desktop = OpenInputDesktop(0, false, DESKTOP_SWITCHDESKTOP);
        if (desktop == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            byte[] buffer = new byte[512];
            uint needed;

            if (!GetUserObjectInformation(desktop, UOI_NAME, buffer,
                                          (uint)buffer.Length, out needed))
            {
                return null;
            }

            int length = 0;
            while (length < buffer.Length && buffer[length] != 0)
            {
                length++;
            }

            return System.Text.Encoding.Unicode.GetString(buffer, 0, length);
        }
        finally
        {
            CloseDesktop(desktop);
        }
    }
}
'@
}

$script:TimelmButtonsDevicePath = '\\.\TimelmButtons'

$script:TimelmButtonNames = @{
    1 = 'Power'
    2 = 'VolumeUp'
    4 = 'VolumeDown'
    8 = 'Assist'
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
    None         = 0
    Tab          = 1
    Enter        = 2
    ShiftF10     = 3
    Lock         = 4
    Shutdown     = 5
    Wake         = 6
    LockOrWake   = 7
    LaunchTarget = 8
    StartMenu    = 9
}

function Get-TimelmAgentActionName {
    <# The name of an agent action id, for the logs and the receipts. #>
    param([int]$Action)
    foreach ($entry in $script:TimelmAgentAction.GetEnumerator()) {
        if ($entry.Value -eq $Action) { return $entry.Key }
    }
    return ('Action{0}' -f $Action)
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
    <#
      Decodes the TIMELM_BUTTON_STATE structure.

      The current version is 64 byte long and knows a fourth button, the
      second version was 56 byte and the first one 48 byte.  The layout is
      append only, so the first 56 byte carry the same values in every
      version.  The counters of the fourth button are behind them.
    #>
    param([byte[]]$Buffer)

    $press = @(
        [BitConverter]::ToUInt32($Buffer, 16),
        [BitConverter]::ToUInt32($Buffer, 20),
        [BitConverter]::ToUInt32($Buffer, 24)
    )

    $held = @(
        [BitConverter]::ToUInt32($Buffer, 28),
        [BitConverter]::ToUInt32($Buffer, 32),
        [BitConverter]::ToUInt32($Buffer, 36)
    )

    if ($Buffer.Length -ge 64) {
        $press += [BitConverter]::ToUInt32($Buffer, 56)
        $held += [BitConverter]::ToUInt32($Buffer, 60)
    } else {
        $press += 0
        $held += 0
    }

    $state = [ordered]@{
        Version       = [BitConverter]::ToUInt32($Buffer, 0)
        Ready         = [BitConverter]::ToUInt32($Buffer, 4)
        Buttons       = [BitConverter]::ToUInt32($Buffer, 8)
        ChangeCounter = [BitConverter]::ToUInt32($Buffer, 12)
        PressCount    = $press
        HeldMillis    = $held
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
    $buffer = [TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_GET_STATE, $null, 64)
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

    $buffer = [TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_WAIT, $request, 64)
    return ConvertFrom-TimelmButtonState $buffer
}

function ConvertFrom-TimelmButtonMapping {
    <#
      Decodes the TIMELM_BUTTON_MAPPING structure.

      The current version is 200 byte long and knows a fourth button, the
      second version was 152 byte and the first one 80 byte.  The layout is
      append only: the three sources sit at offset 8, the three actions at
      offset 80, the source of the fourth button at offset 152 and its
      action at offset 176.
    #>
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

    if ($Buffer.Length -ge 200) {
        $sources += [pscustomobject][ordered]@{
            Index    = 3
            Sid      = [BitConverter]::ToUInt32($Buffer, 152)
            Addr     = [BitConverter]::ToUInt32($Buffer, 156)
            Mask     = [BitConverter]::ToUInt32($Buffer, 160)
            Polarity = [BitConverter]::ToUInt32($Buffer, 164)
            Enabled  = [BitConverter]::ToUInt32($Buffer, 168)
        }

        $actions += [pscustomobject][ordered]@{
            Index            = 3
            HidAction        = [BitConverter]::ToUInt32($Buffer, 176)
            LongPressMillis = [BitConverter]::ToUInt32($Buffer, 180)
            AgentShortAction = [BitConverter]::ToUInt32($Buffer, 184)
            AgentLongAction  = [BitConverter]::ToUInt32($Buffer, 188)
            HidEnabled       = [BitConverter]::ToUInt32($Buffer, 192)
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
    $buffer = [TimelmButtonsNative]::Ioctl($Handle, [TimelmButtonsNative]::IOCTL_GET_MAPPING, $null, 200)
    return ConvertFrom-TimelmButtonMapping $buffer
}

function Get-TimelmButtonMappingVersion {
    <#
      The version of the mapping structure that the driver understands.  A
      tool has to write the mapping in that version, the driver of the
      second version does not accept the four button structure.
    #>
    param([IntPtr]$Handle)

    $mapping = Get-TimelmButtonMapping -Handle $Handle
    if ($mapping.Version -ge 3 -and $mapping.Action.Count -ge 4) {
        return 3
    }
    if ($mapping.Version -ge 2 -and $mapping.Action.Count -ge 3) {
        return 2
    }
    return 1
}

function Set-TimelmButtonMapping {
    param(
        [IntPtr]$Handle,
        [byte[]]$Mapping
    )
    if ($Mapping.Length -ne 200 -and $Mapping.Length -ne 152 -and $Mapping.Length -ne 80) {
        throw 'The mapping structure must be 200 bytes long (152 bytes for the second version, 80 bytes for the first one).'
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
      Builds a TIMELM_BUTTON_MAPPING structure.

      The mode decides who reacts to a short press:

        Agent  the agent answers with TAB, ENTER, the assist target and the
               lock (the default)
        Hid    the driver reports a native volume key, the agent only
               answers a long press and the short press of the power key
        Both   both of them react, only useful to see the two paths at once

      The short press of the power key always belongs to the agent, Windows
      has no native lock and would show its power menu instead.  It locks
      the workstation when it is unlocked and wakes the display when the
      session is locked.

      The version decides the size of the structure: 200 byte for the current
      driver with four buttons, 152 byte for the driver of the second
      version and 80 byte for the first one.
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
        [int]$VolumeDownLongPressMillis = 800,
        [ValidateSet(1, 2, 3)]
        [int]$Version = 3,
        [int]$AssistSid = 0,
        [int]$AssistAddress = 0xC010,
        [int]$AssistMask = 0x01,
        [int]$AssistPolarity = 1,
        [ValidateSet('None', 'Tab', 'Enter', 'ShiftF10', 'Lock', 'Shutdown', 'Wake', 'LockOrWake', 'LaunchTarget', 'StartMenu')]
        [string]$AssistAction = 'LaunchTarget',
        [int]$AssistLongPressMillis = 0
    )

    $size = 200
    if ($Version -eq 2) { $size = 152 }
    elseif ($Version -eq 1) { $size = 80 }

    $mapping = New-Object byte[] $size
    [void][BitConverter]::GetBytes([uint32]$Version).CopyTo($mapping, 0)      # version

    $count = 3
    if ($Version -ge 3) { $count = 4 }
    [void][BitConverter]::GetBytes([uint32]$count).CopyTo($mapping, 4)         # count

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

    if ($Version -ge 2) {
        #
        # The actions of the three buttons: power, volume up, volume down.
        #
        $actions = @(
            @($script:TimelmHidAction.PowerDown, $PowerLongPressMillis, $script:TimelmAgentAction.LockOrWake, $script:TimelmAgentAction.Shutdown),
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
    }

    if ($Version -ge 3) {
        #
        # The fourth button, the assist key of the phone.  It is read from
        # PMIC gpio1 and it is active low.  Windows has no counterpart for
        # that key, so the agent always answers it.
        #
        [void][BitConverter]::GetBytes([uint32]$AssistSid).CopyTo($mapping, 152)
        [void][BitConverter]::GetBytes([uint32]$AssistAddress).CopyTo($mapping, 156)
        [void][BitConverter]::GetBytes([uint32]$AssistMask).CopyTo($mapping, 160)
        [void][BitConverter]::GetBytes([uint32]$AssistPolarity).CopyTo($mapping, 164)
        [void][BitConverter]::GetBytes([uint32]1).CopyTo($mapping, 168)

        [void][BitConverter]::GetBytes([uint32]$script:TimelmHidAction.None).CopyTo($mapping, 176)
        [void][BitConverter]::GetBytes([uint32]$AssistLongPressMillis).CopyTo($mapping, 180)
        [void][BitConverter]::GetBytes([uint32]$script:TimelmAgentAction[$AssistAction]).CopyTo($mapping, 184)
        [void][BitConverter]::GetBytes([uint32]$script:TimelmAgentAction.None).CopyTo($mapping, 188)
        [void][BitConverter]::GetBytes([uint32]0).CopyTo($mapping, 192)
    }

    return $mapping
}

function Test-TimelmWorkstationLocked {
    <#
      True when the workstation is locked.  While the session is locked the
      desktop that has the input focus is the "Winlogon" desktop of the
      secure desktop, otherwise it is the "Default" desktop of the session.
    #>
    $name = $null
    try {
        $name = [TimelmButtonsNative]::GetInputDesktopName()
    } catch {
        $name = $null
    }

    if (-not $name) {
        return $false
    }

    return ($name -ieq 'Winlogon')
}

function Invoke-TimelmWakeDisplay {
    <#
      Turns the display on again and wakes the system out of the modern
      standby state.  The return value carries what the system answered.
    #>
    $previous = [TimelmButtonsNative]::WakeDisplay()
    $nudge = [TimelmButtonsNative]::NudgeMouse()

    return [pscustomobject]@{
        PreviousState = $previous
        NudgeResult   = $nudge
    }
}
