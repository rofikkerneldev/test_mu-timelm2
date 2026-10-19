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
once app retains its Windows chainload behavior.

## Physical v2 result and v3 observability

The 6ae7a04 v2 run accepted the known dispatcher, reported two cores, host/device
support mask 0x18, SSUSB1 type 5 and base 0xA600000. StartController(0,1)
returned EFI_SUCCESS, but both USB2_HC and USB_IO remained absent after the
three-second wait. StopController(0,1) and peripheral restore returned success;
the final host count was zero. The shutdown checkpoint was saved and both boot
entry files subsequently matched the original Windows SHA256.

The user clarified that OTG was absent during that run. The next boot with
OTG attached reached Windows because the one-shot launcher had already restored
the original entry files. Therefore v2 does not establish behavior with an
attached OTG peripheral; a repeat requires staging the launcher again.

Version 3 retains the same request, guards, teardown and firmware-only ending.
It adds read-only snapshots before start, immediately after start, and after
cleanup: QCOM protocol instance revisions/core/mode, same-handle PCI_IO presence,
and counts of BY_DRIVER/BY_CHILD_CONTROLLER open records. It also records the
global PCI_IO handle count, which is not a USB-specific count. These snapshots
do not open/connect protocols or call PCI configuration accessors. Traversal is
bounded to eight QCOM instances and 32 open records per instance; unsupported
revisions are logged without accessing the private core/mode fields.

These observations can distinguish a retained peripheral descriptor from a
host descriptor with no emulation driver or no published host controller. They
do not by themselves prove Type-C role, electrical VBUS or a working mouse.
The Qualcomm reference's static configuration can override requested mode;
that is a possible explanation to investigate, not a conclusion from v2.

For the next physical trial, attach OTG and the mouse before choosing the
Windows boot entry. Wait for shutdown, then return to mass storage for logs.
The launcher runs once, including when no peripheral was attached.

## Physical v3 result and targeted bus binding in v4

The cc6a440 run with OTG attached created a primary core-0/mode-1 instance,
PCI_IO on that instance, and one operational USB2_HC with superspeed capability,
two root ports and 64-bit addressing. Its QCOM protocol had one BY_DRIVER open.
Both root ports reported zero status/change bits after three seconds and no
USB_IO interfaces appeared. This establishes the host/emulation transition,
not a working mouse or proof of connector voltage. In particular the zero port
power status bit is not an electrical VBUS measurement. Mode 4 did not override
the host request in this run. Host stop, peripheral restore and shutdown
completed; both original boot hashes and the BCD hash were verified afterward.

V4 first records the same USB snapshot, then considers a standard
ConnectController retry on the new host handle. The retry requires exactly one
USB2_HC, the same-handle known-owner QCOM revision/core-0/mode-1 descriptor,
PCI_IO and DevicePath, and a successful bounded OpenProtocolInformation query
with no BY_DRIVER open on USB2_HC. Missing callbacks, unknown owners, multiple
hosts, absent resources, malformed records or an already bound bus skip it.
The QCOM BY_DRIVER count is not evidence of a USB2_HC bus-driver open; these are
different protocol interfaces and V4 checks the host interface separately.

Only that verified handle receives ConnectController(NULL driver list, NULL
remaining path, recursive TRUE), after the existing restore/checkpoint/start
gates. No driver is loaded from an external file and no global connection is
requested. Standard bus binding may perform its normal device enumeration,
including USB requests through its own driver; this step is not getter-only.
The app itself adds no port-power, PHY, reset or private VBUS operation.
After another three-second wait it captures USB state again, then follows the
same host stop/peripheral restore/shutdown path regardless of connect status.

The timelm source configuration includes UsbBusDxe, UsbKbDxe and USB storage,
but no UsbMouseDxe. Absence of a mouse UI driver would not by itself explain
zero USB_IO enumeration. UEFI host discovery and Windows host support remain
separate: this probe does not add Windows ACPI resources or retain host mode
across ExitBootServices. V4's physical outcome remains pending.
