# SW42902 bus integration findings

The peripheral KMDF package compiles, but the installed firmware has no SPB host
or touchscreen in ACPI. This is the remaining dependency before a touch test.
Do not add an arbitrary QCOM hardware ID to make an unrelated driver bind.

## The wire protocol of the chip

The protocol was read from the driver of the touch of the phone, the file
`Kernel/touch_sw42902/touch_sw42902.c` and its header in the tree of the
kernel of the user.  The kernel log of a recovery confirms every value of it.

The chip is a SW42902, product id B3W68TIM, firmware version 0.74, chip id 10,
protocol 4.  It boots its firmware from its own flash, the boot loader of the
phone only sets the maker id.  A boot from flash is reported by the driver as
`flash boot : BOOT pass`, so the Windows side does not have to upload the
firmware image `B3W68TIME_0_74.img` as long as the chip reports version 0.74.

### Frame of a transfer

The register address of the chip is 12 bit.  It is split over the two first
bytes of the transfer, the high nibble of the address sits in the low nibble
of the first byte, next to the command.

    byte 0   command | (address >> 8) & 0x0f
    byte 1   address & 0xff
    byte 2   payload of a write, little endian

The command says what the transfer does and how long it is:

| Command | Meaning |
| --- | --- |
| 0x00 | read, up to 4 bytes |
| 0x20 | read, more than 4 bytes |
| 0x40 | write, up to 4 bytes |
| 0x60 | write, more than 4 bytes |

A read is a write of the two header bytes with a repeated start, the chip
answers with the bytes of the register.  A write sends the two header bytes
and the payload after them.  The values of the registers are 32 bit, they are
sent little endian, so the register 0x0C03 with the value 0x8303 goes over the
bus as the bytes `4c 03 03 83 00 00`.

### Registers

| Address | Name | Use |
| --- | --- | --- |
| 0x0024 | BUS_TEST_REG | read and write test of the bus |
| 0x0004 | SYS_RST_CTL | reset of the chip, software |
| 0x0020 | INFO_PTR_ADDR | pointer of the firmware, boot check |
| 0x008C | GDMA_CRC_RESULT | result of the checksum, boot check |
| 0x008D | GDMA_CRC_PASS | pass of the checksum, boot check |
| 0x0600 | TC_IC_STATUS | status of the chip, also the start of a report |
| 0x0601 | TC_STATUS | status of the controller |
| 0x0642 | CHIP_INFO + 0x00 | version of the chip, 4 bytes |
| 0x0644 | CHIP_INFO + 0x02 | product id, 8 bytes, `B3W68TIM` |
| 0x0656 | PT_INFO | channel and revision of the panel |
| 0x0666 | TC_STS | status of the controller |
| 0x0C00 | TC_CMD + 0x00 | device control |
| 0x0C01 | TC_CMD + 0x01 | interrupt control |
| 0x0C03 | TC_CMD + 0x03 | driving control |
| 0x0F85 | ABT_CMD + 0x65 | state of the charger |
| 0x0F88 | ABT_CMD + 0x68 | state of the IME |
| 0x0F8A | ABT_CMD + 0x6A | state of the film |
| 0x0FE4 | SERIAL_SPI_EN | switch the serial SPI off, the bus is I2C |
| 0x0FE5 | SERIAL_I2C_EN | switch the serial I2C off, the bus is SPI |

### Sequence of the start

The driver of Linux does this, in this order:

1. Reset the chip over the reset line, TLMM 38, and wait 90 ms.
2. Test the bus: write and read the register 0x0024 with the patterns
   0x5A5A5A5A, 0xA5A5A5A5, 0xF0F0F0F0, 0x0F0F0F0F, 0xFF00FF00, 0x00FF00FF,
   0xFFFF0000, 0x0000FFFF, 0xFFFFFFFF and 0x00000000.  Every value has to come
   back the same.
3. Read the chip: the version at 0x0642 and the product id at 0x0644.  The
   chip id has to be 10 and the protocol version 4.
4. Read the boot state: 0x008C has to be the fixed checksum, 0x008D and 0x0020
   have to be not zero.  Otherwise the firmware of the chip has to be
   uploaded.
5. Write 0x0FE4 with 0, the serial SPI of the chip has to be off.
6. Write 0x0C00 with 1, the device control.
7. Write 0x0C01 with 1, the interrupt of the chip has to be on.
8. Write 0x0F85 with the state of the charger, 1 when the cable is in.
9. Write 0x0F88 with the state of the IME and 0x0F8A with the state of the
   film.
10. Stop the controller: write 0x0C03 with 0x00000004, wait 30 ms.
11. Start the controller: write 0x0C03 with 0x00008303 for the mode U3.
    The mode U0 is 0x00000001.
12. Read 0x0600, the status of the chip.

### Report of a touch

The chip raises the interrupt on the line TLMM 39 when a touch is there.  The
report is read from the register 0x0600.  The driver of Linux reads it in two
parts, the flexible report:

1. The base part, 48 bytes: the header of 12 bytes, the pen of 24 bytes and
   the first contact of 12 bytes.
2. If the header says that there are more contacts, the rest is read from
   0x060C, 12 bytes for every further contact.

The layout of the 48 bytes, every field is little endian:

| Offset | Field |
| --- | --- |
| 0x00 | ic_status, 4 bytes |
| 0x04 | tc_status, 4 bytes |
| 0x08 | wakeup_type 8 bit, touch_cnt 5 bit, button_cnt 3 bit, pen_cnt 1 bit, abnormal_sts 7 bit, curr_mode 3 bit, palm 1 bit |
| 0x0C | the pen, 24 bytes: in_range, contact, swit1, swit2, pressure 12 bit, battery 2 bit, id, x, y, tilt, azimuth |
| 0x24 | the contacts, 12 bytes each |

A contact of 12 bytes is a set of bit fields:

| Bits | Field |
| --- | --- |
| 0..4 | track id |
| 5..7 | tool type |
| 8..15 | angle |
| 16..17 | event |
| 18..31 | x |
| 32..45 | y |
| 46..53 | pressure |
| 54..63 | reserve |
| 64..73 | reserve |
| 74..87 | width major |
| 88..101 | width minor |

The x and the y of the chip are already in the units of the panel, the driver
of Linux copies them without a scale.  The panel of the phone is 1080 by 2460.

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

