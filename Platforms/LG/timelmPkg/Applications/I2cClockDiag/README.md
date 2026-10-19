# Standalone I2C clock and USB host query app

This ARM64 UEFI application asks the existing EFI_CLOCK_PROTOCOL for IDs,
enabled/on status and configured frequency of the touch engine/wrapper clocks.
It does not read MMIO directly, enable clocks, change rates, select pins, reset hardware
or issue I2C transfers. It is not included in the normal firmware image.

The USB snapshot enumerates existing USB2_HC/USB_IO handles, queries host state,
capabilities and root-hub port status, and reads cached device/interface
descriptors. No controller connection, role switch, reset, port power request,
change-bit acknowledgement or USB transfer is submitted. Enumeration is bounded
to 4 controllers, 16 ports per controller and 16 interfaces. An absent protocol
does not identify whether role selection, PHY/power or binding failed; the port
power bit is not a measurement of connector VBUS. The getter contracts are in
the [UEFI USB specification](https://uefi.org/specs/UEFI/2.11/17_Protocols_USB_Support.html).

Build with the pinned Mu_Basecore headers and clang/lld:

```sh
git submodule update --init --depth 1 Mu_Basecore
bash Resources/Scripts/build_i2c_clockdiag.sh
```

The output is `Build/I2cClockDiag/I2cClockDiag.efi`. The script checks ARM64 PE,
EFI application subsystem and an empty import table. It links no Windows CRT,
boot services library, or Mu runtime. The clock protocol header's original
Linux Foundation BSD license remains in its existing QcomPkg location.

For a future manual UEFI Shell session on the phone, put the app on the ESP,
select that filesystem (verify its mapping first), then run for example:

```text
fs0:\I2cClockDiag.efi
```

The app displays console output and appends the same report to
`timelm-i2c-clockdiag.txt` in the root of the filesystem from which it was
launched. Previous captures are preserved. It does not change boot files,
partition metadata, Windows registry or hardware state. If launched from FV
or a read-only filesystem, the log operation reports an error and the console
output is still available. The original clock-only once launcher has completed
on a V60; the added USB snapshot requires a separate physical run with OTG
connected before firmware starts.

An absent clock protocol, unsupported older ABI or unknown clock name is useful
diagnostic output; it does not justify calling an unverified ABI or touching
GCC registers. An enabled clock now does not prove retention after
ExitBootServices, nor firmware/pinmux/reset ownership. Those still need proof
before setting the Windows host's FirmwareHandoffVerified gate.

## Once-only Windows boot launcher

For devices without a file browser/Shell, the build also produces
`I2cClockOnce.efi`. This variant is intended to temporarily occupy both
`EFI/Microsoft/Boot/bootmgfw.efi` and `EFI/Boot/bootaa64.efi` on the ESP, with
immutable original copies next to them named `bootmgfw.timelm-i2c-original.efi`
and `bootaa64.timelm-i2c-original.efi`. Staging must verify the current original
images against WindowsBootReference.json, back them up to the PC and ESP, then
verify both replacement files before unmounting. BCD and partition layout are
not edited. Do not deploy this variant as a general boot manager replacement.

On execution, it checks both backups against the expected size/CRC32 and checks
their bytes match. It restores both normal boot entries and reads them back
before calling any clock protocol function. Restore failure stops before clock
queries or chainload. On success, it saves a checkpoint, queries clocks, saves
the log and starts the restored canonical Windows Boot Manager with its original
load options. A missing clock protocol is logged and still permits Windows boot.
The backup files remain available for Recovery rollback. Restoring boot files
is filesystem I/O, with normal power-interruption limits. The clock-only version
restored both entries to their original SHA256 and reached Windows on the V60.
Host tests verify restore ordering before both clock and USB queries. USB tests
cover absent/null protocols, query failures, handle cleanup and bounded traversal
with all mutation/transfer callbacks left NULL.

WindowsBootReference.json contains only observed size/CRC32/SHA256, not Windows
binary data. CRC32 is used as a runtime corruption check; installation must
use the stronger SHA256 comparison. This exact-image check intentionally
requires updating the reference after a Windows Boot Manager update.

## Optional transient host experiment

The build also produces `UsbHostProbeOnce.efi` and `usb-host-probe.json`.
This separate variant requests and tears down a native primary USB host before
Windows chainload; it is not a getter-only snapshot. Its exact firmware ABI and
owner checks, restore/checkpoint ordering, cleanup rules and manual-reboot
failure behavior are documented in [USB-HOST.md](USB-HOST.md). It writes a
separate `timelm-usb-hostprobe.txt`. Do not substitute it for the normal snapshot
app without the staging checks and original EFI backups.
