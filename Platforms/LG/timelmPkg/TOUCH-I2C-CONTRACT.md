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

Choose a demonstrably compatible Kona GENI SPB host or implement a FIFO host.
Resolve its power/clock/pinmux ABI and initialize the engine in I2C mode before
exposing it. Start with one controller and the internal touch only. Add the
peripheral LGSW4290 with I2cSerialBusV2 0x28, GpioInt Edge/ActiveLow pin 39,
and dependencies on that host and the actual GPIO provider. Implement verified
reset/power ownership rather than relying on Recovery's retained state.

The first hardware check must enumerate the host, read the B3W68TIM product ID,
and show interrupt increments. Only then test HID coordinates, ten contacts,
all-up, cold boot and resume. Host decoder tests and WDK builds cannot answer
these hardware questions.
