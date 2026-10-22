# SW42902 bus integration findings

The peripheral KMDF package compiles, but the installed firmware has no SPB host
or touchscreen in ACPI. This is the remaining dependency before a touch test.
Do not add an arbitrary QCOM hardware ID to make an unrelated driver bind.

## Board resources observed in Recovery

| Resource | Value |
| --- | --- |
| Controller | `/soc/i2c@a94000`, qcom,i2c-geni |
| MMIO | 0x00A94000, size 0x4000 |
| Interrupt | SPI 358 / GSIV 390, level high |
| Vendor DT label | qupv3_se13_i2c (zero-based overall SE 13) |
| Wrapper | QUPv3_1 at 0x00AC0000, local engine 5 |
| Bus pins | TLMM 36/37, function qup13, 2 mA, bias disabled |
| Clock cells | GCC se-clk 0x74, m-ahb 0x86, s-ahb 0x87 |
| Peripheral | I2C 7-bit address 0x28, product B3W68TIM |
| Touch interrupt | TLMM 39, falling edge observed in live IRQ listing |
| Reset / supplies | TLMM 38 / 67 and 68, reset settling 90 ms |

Clock indices are specific to the Recovery vendor DT binding. They are not
Windows PEP resource identifiers. Linux adapter i2c-2 is also not a Windows UID.

## References compared

The pinned Silicium-ACPI alioth DSDT uses QCOM2510 for I2C. Its UID 12 controller
maps 0xA8C000 (vendor overall SE 11). That suggests one-based UID 14 for 0xA94000,
but this is an inference until checked against the chosen Windows driver's ABI.
Those controllers depend on PEP0. The booting timelm DSDT has no PEP0, and prior
qcppx integration failed signature/policy checks before being disabled.

The separately examined WOA-Project/windows_silicon_qcom_kona qci2c8250 INF
version 1.0.2100.0 matches QCOM2511 and defines instances 2/5/7/8/10 only. Its
binary identifies internally as qci2c8180. Alioth uses QCOM2511 for ADC devices.
Neither the filename nor an INF installation establishes compatibility with
timelm's engine 13, clock plan, or firmware protocol. The reference files remain
outside this repository; no proprietary binary is redistributed here.

The installed qci2c_i INF targets QCOMFFEA/SC8380. The requested WOA-Kona/Drivers
source provides GPIO/SPMI/PMIC, without an I2C host implementation. The G8 touch
driver is an SPB client, so it cannot replace the missing host.

## Concrete next integration

A new source prototype is under `GPLDrivers/Windows/KonaGeniI2c`: a bounded
FIFO SPB host for this one engine/address. ARM64 WDK compilation and FIFO
ASan/UBSan tests pass in [run 39201708719](https://github.com/rofikkerneldev/test_mu-timelm/actions/runs/39201708719).
It is a polling prototype, not a production interrupt-driven host. It supplies
neither a clock/power provider nor a GENI firmware loader. Startup is gated
before MMIO access and the gate is off in the INF.

`Experimental/TouchI2c.asl` now declares TIML0001 and LGSW4290 with the observed
MMIO/interrupt, I2cSerialBusV2 0x28 at 100 kHz and GpioInt Edge/ActiveLow pin 39.
It compiles with no errors/warnings but both devices have _STA=0 and the table
is not included in the booting image. Reset/supply ownership remains required.

The standalone `Applications/I2cClockDiag` app queries the existing firmware
clock protocol without changing clocks or directly reading MMIO, and appends its report
to a file. It is intended to determine whether the clock provider and engine
clock names are actually available in the booting UEFI. Its snapshot alone
does not establish clock retention across ExitBootServices, pinmux, firmware
ownership, or reset/power handling. Those are the remaining handoff work before
activating the host and touchscreen. Do not toggle the registry/ACPI gates just
to get past a start failure.

The first hardware check must enumerate the host, read the B3W68TIM product ID,
and show interrupt increments. Only then test HID coordinates, ten contacts,
all-up, cold boot and resume. Host decoder tests and WDK builds cannot answer
these hardware questions.

## The wire protocol of the chip comes from ftrace

The maintainer of the G8 touch, who made the touch of that phone work, gets
everything the chip needs from a trace.  The trace shows the bytes that
really go over the bus, so the register map, the init sequence and the
report format of the chip do not have to be guessed.

That is the missing piece on the Windows side.  The host of the prototype
still does not know the protocol of the SW42902: the register width, the
order of the init writes and the length of a report.

Two scripts were added for it:

- `Resources/Scripts/TouchFtrace/capture_touch_ftrace.sh` runs on the phone
  with Android and root.  It turns on the i2c trace points of the kernel,
  traces the transfers of the address 0x28 and saves the trace next to the
  log of the kernel.
- `Resources/Scripts/TouchFtrace/analyze_touch_ftrace.py` turns such a
  capture into a register map, an init sequence and the length of the read
  reports.  It writes `touch-ftrace.json` and `touch-ftrace.md`.

The capture is read only, it does not write to the chip and it does not
change the boot image.  The result is the input for the host and for the
client, so that both use the same protocol as the boot loader of the phone.

### The capture runs in a recovery as well

The script stays in the plain POSIX shell, so it runs on a phone with Android
and in a recovery of AOSP or of LineageOS.  The shell of a recovery is mksh,
it has no arrays and no bash, and the find of toybox has no -printf, so the
list of the trace points is made with the glob of the shell.  The script was
checked with dash and with the shell of busybox.

    adb reboot recovery
    adb root
    adb push capture_touch_ftrace.sh /tmp/
    adb shell
    sh /tmp/capture_touch_ftrace.sh /data/local/tmp/touch-ftrace 60
    adb pull /data/local/tmp/touch-ftrace

The tracefs is often there but not mounted in a recovery, the script mounts it
by itself.  The result is written to /data, both recoveries have it.  The
analyser is a python script and runs on the build PC, the capture is pulled
there.

What a recovery gives and what it does not:

- A recovery with a working touch, for example TWRP or the recovery of
  LineageOS, reads the chip over and over again.  The trace of that traffic
  shows the report of the chip, its length and the moment of the interrupt.
  That is the best source for the format of the report.
- A recovery of AOSP without a touch has almost no traffic on the address
  0x28.  The trace is then nearly empty.
- The driver of the touch is built into the kernel of a recovery, so its
  probe runs while the kernel starts, before the trace can be switched on.
  The sequence of the probe is therefore usually not in the trace of a
  recovery.  With Android the driver can be a module, and the third argument
  of the script loads that module again while the trace runs, so that the
  sequence of the probe is in the trace as well:

      sh capture_touch_ftrace.sh /data/local/tmp/touch-ftrace 30 sw42902

  If the module is built in there as well, the log of the kernel is the
  second source: a driver of a touch prints the chip id and often its
  register writes.  The capture script saves that log as well.

