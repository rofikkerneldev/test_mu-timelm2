# Experimental SW42902 Windows peripheral driver

This is a source candidate for the LG V60 timelm internal B3W68TIM touchscreen.
It is **not a working touchscreen package yet**. The packet decoder passes host
tests, including a real B3W68TIM v0.74 one-finger Recovery capture. A 60-frame
Recovery capture decoded three one-finger and 57 empty reports without malformed
frames. This validates the wire format, not Windows transport or HID operation.
The current [native Windows bring-up](../../../Platforms/LG/timelmPkg/TOUCH-WINDOWS-NATIVE.md)
adds optional clock/GPIO handling, but Recovery uses GPI DMA and the Windows
GPI transport remains unfinished. The initial ARM64 KMDF package built with WDK in
[Actions run 39199989979](https://github.com/rofikkerneldev/test_mu-timelm/actions/runs/39199989979)
at `ad14ab4cdb9d1f7fa6769bf891789851b1dede17`; PE machine type is ARM64.
ASan/UBSan decoder tests also passed. It has not been tested on the phone.
The installed target reports Windows 11 26H2 ARM64 build 26300.9457.
Do not install it as a root-enumerated device: it requires real ACPI I2C and
GPIO interrupt resources and a functioning Windows SPB controller driver.

## Provenance

The HID/KMDF scaffold comes from [Project-Aloha/sw42000-touch](https://github.com/Project-Aloha/sw42000-touch)
at `98ef6043ff3d2c6ec388a492e27aeb1639e98de5`, under its GPL-3.0 license.
Original Microsoft notices are retained. The new wire decoder uses explicit
little-endian loads instead of compiler bitfield layout. Register and packet
facts were checked against the LG V60 vendor kernel:

- [touch_sw42902.h](https://github.com/rofikkerneldev/lgv60nextgen_rofikkernel/blob/lineage-23.0/drivers/input/touchscreen/lge/lgsic/sw42902/touch_sw42902.h)
- [touch_sw42902.c](https://github.com/rofikkerneldev/lgv60nextgen_rofikkernel/blob/lineage-23.0/drivers/input/touchscreen/lge/lgsic/sw42902/touch_sw42902.c)

No Linux driver source is linked into this Windows driver. Linux DRM/ASoC/IIO
drivers do not implement the Windows display/audio/input driver interfaces.

## Changes from the LG G8 reference

- Native X/Y range 1080/2460 and a separate `ACPI\LGSW4290` match.
- SW42902 packets have a 12-byte header, a 24-byte pen block and up to ten
  12-byte finger records. The first finger starts at byte 36, not byte 12.
- Decoder checks IRQ type, LPWG reports, count, packet length, coordinate bounds,
  duplicate/invalid contact IDs, hardware error flags and palm indications.
  Pen input is not exposed.
- The G8 register-write sequence is removed. The candidate probes the observed
  product ID before applying minimal SW42902 normal-scan controls. It does not
  upload firmware or alter touch flash.
- SPB reads use a write/read sequence with a 100 ms timeout. Failed or short
  transfers are not decoded. D0 entry propagates initialization failures.
- A pending report preserves the latest contact state when no HID read is
  waiting, including the last release frame. Intermediate frames can coalesce.
- Build project supports ARM64 only and removes the original developer's
  absolute paths and WPP configuration.

## Hardware contract and remaining integration

Recovery captured on 2026-10-19 identifies:

| Resource | Observed value |
| --- | --- |
| Device | `/soc/i2c@a94000/sw42902`, `lge,sw42902` |
| Linux adapter | i2c-2; this number is not a Windows controller identity |
| Address | 7-bit `0x28` |
| GENI controller MMIO | `0x00A94000`, length `0x4000` |
| Controller interrupt | DT SPI 358, GSIV 390 |
| Reset | TLMM GPIO 38 |
| Touch IRQ | TLMM GPIO 39 |
| VCL/VDD enables | TLMM GPIO 67 / 68 |
| Reset settling | 90 ms |
| Firmware | v0.74, product `B3W68TIM` |

The DT interrupt cells contain level-low plus oneshot flags (`0x2008`), while
the LG driver's separate `irqflags=2` selects falling edge. Live Recovery
`/proc/interrupts` confirms GPIO 39 is registered as Edge. The Windows GpioInt
must use Edge/ActiveLow; do not copy Linux flag values into ACPI.
Use TLMM-local pin numbers, not Linux's dynamic
global GPIO numbers 1138/1139/1167/1168.

Current firmware exposes only UFS, GPIO, SPMI, PMIC and CPUs. Neither a touch
device nor an I2C host exists in the installed ACPI namespace. The current
WOA-Kona driver set contains GPIO/SPMI/PMIC only, not an SPB I2C host.
The installed OS does include `qci2c_i.inf`, but it targets QCOMFFEA/SC8380;
that is not evidence of a usable Kona driver. Do not spoof that hardware ID.
The separately investigated `qci2c8250` BSP package matches QCOM2511, while the
alioth ACPI I2C devices use QCOM2510. Its INF has no instance 14 configuration,
and its binary's internal name is qci2c8180. That package is an unverified
reference, not a demonstrated solution for this controller. See the
[bus integration findings](../../../Platforms/LG/timelmPkg/TOUCH-I2C-CONTRACT.md).

Before enabling this candidate:

1. Obtain or implement a Kona GENI I2C Windows SPB host and its complete ACPI
   clock/power/pinmux/interrupt contract. A new HID alone cannot supply it.
2. Validate the host at MMIO `0xA94000`, using the actual driver's hardware ID
   and resource ABI; do not invent a QCOM ID or reuse an alioth bus number.
3. Expose `LGSW4290` with I2cSerialBusV2 address `0x28`, GpioInt pin 39, `_DEP`
   on the real host and GPIO provider, and board-verified reset/power handling.
4. Build/sign the candidate, verify enumeration/interrupts and probe product ID,
   then test corner coordinates, ten fingers, all-up, pen proximity and reboot.

The candidate relies on firmware to power/reset the IC. Suspend/resume,
recovery after I2C failure, active pen, LPWG and dual-screen touch are unfinished.
No speculative ACPI devices are added to the known booting DSDT.

## Build and tests

With Visual Studio Build Tools, ARM64 C++ tools and Windows 11 WDK:

```powershell
./Resources/Scripts/build_sw42902_touch.ps1
```

The historical service/binary name `vhidmini` is retained. Remove a conflicting
G8 `vhidmini` package before any future validated install; do not mix them.
The INF matches only LGSW4290. Catalog signing and Windows policy validation
remain required before deployment.

Host decoder tests on Linux/WSL:

```sh
gcc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  GPLDrivers/Windows/Sw42902Touch/tests/protocol_test.c -o /tmp/sw42902-test
/tmp/sw42902-test
```

These tests establish wire decoding and bounds safety. WDK compilation is
separately verified by Actions. Neither check establishes I2C operation,
GPIO interrupts or working touch on Windows.
