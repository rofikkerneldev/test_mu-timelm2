# Native Windows touchscreen bring-up

Touch is the current priority. USB host experiments and broad PMIC work are
set aside. The user reports normal Windows OOBE again. The traced USB v2
launcher has not been deployed. Keep the original Windows EFI entries.

## Recovery result: GPI is the active transport

Three controlled write/read transactions (header 26 44, eight-byte read) returned
42 33 57 36 38 54 49 4d: B3W68TIM. GPI1 GPII0 GSIV 311 advanced 225 to 234,
while GENI GSIV 390 stayed zero. The vendor driver's transfer selection uses
the GSI path when its read-only FIFO-disable value is nonzero. This strongly
identifies the current Recovery bus as GSI-only, rather than a working FIFO
path. It does not establish register state after a separate Mu boot.

A subsequent 60-frame report capture contained three one-finger frames and 57
empty frames. All passed the actual Windows decoder. Observed coordinates were
(89,300), (649,578), (501,1526). The first frame is retained as a regression
fixture. These are Recovery reads, not Windows input validation.

The FIFO profile must not be deployed as the V60 touch solution. The native
clock/GPIO lifecycle and SW42902 client are shared with the new GPI transport.
FIFO startup returns STATUS_NOT_SUPPORTED for FIFO-disabled firmware, before
opening the touch power/reset GPIO connections. GPI has its own resource and
DMA prerequisites; it does not fall back to FIFO.

Following that finding, a [source GPI backend](../../../GPLDrivers/Windows/KonaGeniI2c/GPI.md)
has been integrated with the host. The separate TouchGpiWindows.asl profile and
NativeGpiEnabled option select it; the old FIFO profile is retained separately.
DMA mapping checks, ownership, completion validation and teardown are explicit.
Physical Windows validation and translated SMMU support remain pending.

Recovery has CONFIG_DEBUG_FS and CONFIG_DEVMEM disabled, so no direct GCC/GENI
register snapshot was obtained. No raw register access was forced.

The public Kona BSP contains qcgpi8250 and qci2c8250 at revision
22221a09e02cb7054792427af60299b1c34d3c3e. The GPI INF uses QCOM2593 and contains
QUP1 GPII0 GSIV 311, matching the observed interrupt. This is insufficient for
installation: qci2c still lacks instance 14, its HID differs from alioth, and
alioth uses QCOM2593 on a sensor-related node. No guessed IDs were added.
See [the GPI transport contract](TOUCH-GPI-CONTRACT.md) for the remaining work.

The new native path adds board initialization to the GENI SPB prototype; it
does not claim working touch until the phone produces an identified SW42902
packet and a Windows HID report. Default registry gates and both ACPI device
statuses remain disabled. No phone installation has occurred for this change.

## Windows implementation

- The native FIFO profile uses TBCF=0x54420101, three MMIO resources and four
  exclusive GPIO connections (Experimental/TouchWindows.asl). The GPI profile
  uses TBCF=0x54420201, five MMIO resources, raw GSIV311 and the same four GPIO
  connections (Experimental/TouchGpiWindows.asl). These are alternative profiles.
- GCC base 0x100000: only pages at 0x118000 and 0x152000 are mapped. Wrap1
  AHB votes are bits 20/21 and local SE5 vote is bit 27 of GCC+0x52008.
- Non-DFS: select 19.2 MHz TCXO without changing PLLs; refuse an already-voted
  engine at another rate. RCG update and branch wait are bounded to 200 us.
- DFS: preserve the firmware performance table, find an integer 19.2 MHz TCXO
  slot, select it through GENI and confirm the observed GCC performance level.
  Absence of that slot is a startup error, not permission to overwrite DFS.
- Require idle I2C firmware before touch power/reset. FIFO additionally requires
  FIFO availability; GPI requires an unallocated GPII0 instance and a verified
  DMA mapping. Missing I2C firmware is logged and refused. No firmware is loaded.
- Reserve reset 38, VCL 67, VDD 68 and bus pins 36/37 through Resource Hub.
  The opt-in GPIO v2 interface selects qup13, no pull, 2 mA on the reserved
  bus pins, preserving unrelated TLMM bits and saving their previous fields.
- Hold reset low, VCL high, wait 1 ms, VDD high, wait 10 ms, release reset,
  wait 90 ms. Cleanup follows reset low, VDD low, VCL low, then pinmux/clock
  restoration. Partial startup is included in cleanup.
- The client probes B3W68TIM before normal-scan writes and reports 1080x2460
  HID coordinates. Scan/IC interrupts start in D0EntryPostInterruptsEnabled,
  after Windows has armed the GPIO interrupt. The IC interrupt is disabled in
  D0ExitPreInterruptsDisabled while the SPB target is still open. This avoids
  losing the first falling edge during startup. No touch firmware is flashed.

The native mode requires NativeBoardInitEnabled=1 on the actual TIML0001
device. The GPI profile also requires NativeGpiEnabled=1. These are separate
from FirmwareHandoffVerified; native startup does not set or pretend to satisfy
the old firmware-handoff gate. All activation gates remain disabled by default.

## Remaining device-dependent limits

The existing firmware must already establish nonsecure SE ownership, I2C
microcode and sufficient fabric access. This prototype does not supply SCM
ownership reassignment or RPMh/interconnect votes. Its GPI adapter supports
only an already-established firmware BYPASS mapping for SMMU stream 0x56;
translated Windows IOMMU/domain support is not implemented. The actual stream
mapping after a Mu boot has not been established. No SMMU register is written.
Opening resource mappings cannot prove fabric/secure access is safe. The
disabled experimental profile must first be reviewed against the phone's
firmware state; a build result alone is not hardware acceptance.

There must be no competing PEP/GCC driver managing these votes. RMW preserves
unrelated vote bits, but is not arbitration with another clock manager.
Suspend/resume remains unsupported: the controller refuses a second D0 entry
after a successful first start. Runtime idle is explicitly disabled. The GPI
adapter retains the DMA buffer/adapter until reboot if bounded teardown cannot
confirm quiescence, skips clock/power restoration and refuses restart. These
are bring-up limits; see GPI.md for the exact failure behavior.

## Build and verification

Build native host and touch client with build_geni_i2c.ps1 and
build_sw42902_touch.ps1. Build the pinned Kona source with
build_kona_drivers.ps1 -TimelmTouchFixes (use a clean checkout, not an edge-only
patched checkout). This switch includes the previous GPIO edge fixes. The
dedicated timelm-touch-windows workflow builds both packages, compiles both
disabled ACPI profiles, and runs ASan/UBSan FIFO, GPI, decoder, touch startup
ordering and board lifecycle tests.

Clock/power tests inject wrong frequency/DFS, dirty configuration, timeouts,
partial power-up and failed cleanup. Successful tests establish software
behavior, not device ownership, FIFO availability, GPIO IRQs or usable touch.

Registry diagnostics on the real TIML0001 device include TimelmHostStage,
TimelmHostStatus, TimelmBoardStage/Status, TimelmClockResult, clock config/DFS,
GENI firmware/FIFO/status and cleanup result. First hardware acceptance is a
successful host start, B3W68TIM read, interrupt increments and decoded touch.

Code at ad2aa09c32698d3de4fef0a7c0bf246aa1794f53 passed all three jobs in
[Actions run 39239450021](https://github.com/rofikkerneldev/test_mu-timelm/actions/runs/39239450021):
ARM64 GPI host/client, patched GPIO/SPMI/PMIC packages, and the portable tests
and ACPI checks above. The decoder test includes the captured v0.74 frame.
Windows PowerShell 5.1 collector validation also passed. No experimental package
or ACPI profile has been installed on the phone; Windows DMA/IRQ/HID validation
and support for translated SMMU mappings remain pending.

## Primary references

Board pin and power timing facts come from the captured Recovery DT and the
[LG SW42902 vendor driver](https://github.com/rofikkerneldev/lgv60nextgen_rofikkernel/blob/lineage-23.0/drivers/input/touchscreen/lge/lgsic/sw42902/touch_sw42902.c).
Clock offsets and DFS format were checked against
[Linux v6.15 gcc-sm8250.c](https://github.com/torvalds/linux/blob/v6.15/drivers/clk/qcom/gcc-sm8250.c)
and [clk-rcg2.c](https://github.com/torvalds/linux/blob/v6.15/drivers/clk/qcom/clk-rcg2.c).
GPIO transport follows Microsoft's
[KMDF GPIO connection contract](https://learn.microsoft.com/windows-hardware/drivers/gpio/connecting-a-kmdf-driver-to-gpio-i-o-pins).
