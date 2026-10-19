# Transient USB host probe for the captured LG V60 firmware

`UsbHostProbeOnce.efi` is a separate experimental build. Unlike the normal
clock/USB snapshot apps, it requests a temporary primary host using the native
Qualcomm USB configuration protocol. It restores and verifies the original
Windows EFI entry files before any request. It writes `timelm-usb-hostprobe.txt`
on its launching filesystem and never updates boot partitions or NVRAM itself.
It is not packaged into the normal timelm firmware image.

The purpose is to distinguish a missing host-start request from failure in the
stock USB driver, Type-C/power configuration, PHY or driver binding. A successful
native function return alone does not prove that the host or mouse exists; the
USB2_HC/USB_IO snapshots and VID/PID are the required evidence. This probe does
not add Windows USB ACPI resources or establish an OS handoff. Version 2 saves
its result and requests platform shutdown before Windows is started, including
skipped and failed tests. If shutdown is unavailable, it waits in firmware for
a manual reboot. This avoids interrupting Windows OOBE on every test.

## ABI and owner verification

The minimal local prefix in UsbHostProbe.h follows the original Qualcomm
interface and controller API, published in these reference snapshots:

- [BOOT.XF.3.3 EFIUsbConfig.h](https://github.com/SwedMlite/BOOT.XF.3.3/blob/55ff7c1920ccf084951b2770d46ffcbe8917864f/QcomPkg/Include/Protocol/EFIUsbConfig.h)
- [Protocol wrappers](https://github.com/SwedMlite/BOOT.XF.3.3/blob/55ff7c1920ccf084951b2770d46ffcbe8917864f/QcomPkg/Drivers/UsbConfigDxe/UsbConfig.c)
- [SM8250 USB configuration implementation](https://github.com/SwedMlite/BOOT.XF.3.3/blob/55ff7c1920ccf084951b2770d46ffcbe8917864f/QcomPkg/SocPkg/8250/Library/UsbConfigLib/UsbConfigLib.c)

These are reference source snapshots, not proof that every Qualcomm firmware
uses the same ABI. The captured LG UsbConfigDxe SHA256 is
`cbdadeadc2d71a1ea777b64be688a228b50db46227ad8dea16a8c9df893531a9`.
Its protocol table at RVA 0x15188 has revision 0x10005. Static inspection matches:

| Method | Protocol offset | Function RVA |
| --- | --- | --- |
| GetCoreBaseAddr | 0x08 | 0x141c |
| GetUsbHostConfig | 0x38 | 0x14d0 |
| StartController | 0x50 | 0x14ec |
| StopController | 0x58 | 0x1534 |
| GetCoreCount | 0x78 | 0x15dc |
| GetSupportedMode | 0x80 | 0x1650 |

The start/stop wrappers forward core/mode from w1/w2. The core-0 host-config
path writes SSUSB1=5. Mode 1 is xHCI host; mode 4 is superspeed peripheral.
Later fields differ across interface revisions (including AlwaysConnected),
so the app never accesses the VBUS methods or assumes their offsets.

At runtime all six pointers must belong to one LoadedImage of size 0x17000,
at the matching RVAs, with matching 16-byte code prefixes. This is a compatibility
check, not image authentication. A mismatch skips the experiment. Static asserts
check the 64-bit prefix layout. The app reads the firmware override variables
with the captured vendor GUID and logs their status; it never writes them.

## Request and cleanup

Before requesting host, the app requires revision 0x10005, the known owner,
either a core-0/peripheral descriptor or the exact global dispatcher tuple
(core=2, mode=0x10000), 1..2 cores, advertised host support, SSUSB1 type 5,
reported base 0xA600000, and no existing USB2_HC handles. It saves and flushes a
checkpoint before the request; a checkpoint error skips the request.

The first physical run at 33a8a1a matched the revision/owner but skipped the
request because the descriptor was the global dispatcher. The earlier check
incorrectly assumed LocateProtocol must return a primary/peripheral instance.
The reference UsbConfigInit implementation explicitly creates the dispatcher
at index USB_CORE_MAX_NUM_SM_8250, with USB_INVALID_MODE, for clients to request
controllers when no valid controller handle exists. Version 2 accepts only that
additional tuple and requires GetCoreCount=2 for it. All getters and mutations
still receive the explicit target core 0; core 2 is never started or stopped.

It calls StartController(core=0, mode=1), waits 3 seconds on success, and queries
the existing USB protocols. Regardless of start status, it then calls native
StopController(core=0, mode=1) and StartController(core=0, mode=4) for cleanup.
It considers cleanup verified when stop succeeded or reports NOT_STARTED,
peripheral restore succeeded, and the final host enumeration succeeds with zero
USB2_HC handles. No direct MMIO, explicit VBUS force-enable, USB controller reset, generic
ConnectAll, private structure modification or firmware-variable write is used.

The app saves the log and requests platform shutdown after the test, regardless
of cleanup status. It never returns to BDS or chainloads Windows. If the platform
shutdown function returns, it waits for a manual reboot instead.
Both Windows entry files have already been restored, so the test is not rerun
on the next boot. Native firmware calls can still hang or fail on hardware;
the restore/checkpoint ordering makes a subsequent manual Recovery boot usable.

Native static-mode overrides may ignore a host request and return success while
remaining peripheral. Such a result is useful evidence, not a working host fix.
The app intentionally does not remove overrides or assume they are safe to change.

Host tests cover owner/code mismatch, overflow bounds, ABI/core/base/mode gates,
preexisting hosts, checkpoint failure, native errors, absent host after a success
return, cleanup failure and residual hosts. The host-enabled once variant also
runs restore-before-query, shutdown-before-Windows (zero LoadImage/StartImage
calls), corrupted backup and restore-failure tests. The default getter-only
once app retains its Windows chainload behavior. A physical host request using
the corrected dispatcher gate remains pending.
