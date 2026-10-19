# timelm GENI I2C SPB prototype

Experimental Windows KMDF/SpbCx controller for the LG V60 touch bus at 0xA94000.
This implements FIFO transfers; it is not a renamed Qualcomm binary. The ID
TIML0001 belongs only to this prototype and does not claim Qualcomm compatibility.
The implementation is GPL-2.0-only, in a separate driver from the GPL-3.0 G8
touch client scaffold.

## Status and limits

Host ASan/UBSan tests pass for every transfer length 1..256, FIFO boundaries,
write/read repeated-start command encoding, NACK, short completion, overflow,
cancellation, timeout and refusal to reuse a failed controller. These tests
model hardware behavior; they do not prove that behavior on the V60.
ARM64 WDK compilation also passes in
[run 39201708719](https://github.com/rofikkerneldev/test_mu-timelm/actions/runs/39201708719).
The phone has not run this host. The disabled SSDT compiles with no warnings.

The fixed bus profile is 7-bit address 0x28, 100 kHz from a verified 19.2 MHz
source, at most two transfers per atomic request, 256 bytes per transfer,
up to eight MDL segments and one shared 50 ms request deadline. Polling uses
20 us stalls at PASSIVE_LEVEL. It is unsuitable for a production streaming
touch path; an interrupt-driven state machine is a later requirement.

Both standalone read/write and SPB sequence callbacks are implemented. Requests
with transfer delays, other targets/speeds, 10-bit addressing or explicit
lock/unlock sequences are rejected. Read data is copied back only after that
transfer succeeds. A failure aborts the sequencer, invalidates the controller
and completes with an error instead of returning success for stale data.

## Firmware handoff is still missing

The driver does not enable GCC clocks, vote RPMh/interconnect power, select
TLMM function qup13, load GENI firmware, or power/reset the SW42902. Those are
mandatory before accessing its MMIO. It cannot inherit those guarantees from
Recovery because booting the UEFI image changes ownership and power state.

The INF therefore sets FirmwareHandoffVerified=0 and SourceClockHz=0 in the
device key. PrepareHardware fails before any MMIO read unless a separately
validated handoff is explicitly recorded (verified=1, source=19200000).
These are development gates, not evidence of readiness; do not set them merely
to bypass a start failure. After a successful start, D0 re-entry is refused
because power restoration/resume is not implemented. No runtime idle policy
is enabled. Sleep, resume and driver restart require further lifecycle work.

After the external handoff is proven, startup also checks that the engine
firmware identifies I2C, the FIFO interface is enabled, the sequencers are idle,
the FIFOs are empty and both FIFOs have supported depth/32-bit words. It sets
FIFO packing, timing and local status masks with global GENI IRQ output gated.
Whether status remains usable with that IRQ gate on this firmware is an
explicit hardware validation item; host simulation cannot establish it.

The separate `Platforms/LG/timelmPkg/Experimental/TouchI2c.asl` declares the host
and touch resources with _STA=0. It is not included in the booting DSDT or
firmware build. No _PS0/_PS3 implementation or supply/reset ownership is faked.

## References and build

Register layout, packing and STOP_STRETCH semantics were checked against
[Linux v6.15 i2c-qcom-geni.c](https://github.com/torvalds/linux/blob/v6.15/drivers/i2c/busses/i2c-qcom-geni.c),
[qcom-geni-se.c](https://github.com/torvalds/linux/blob/v6.15/drivers/soc/qcom/qcom-geni-se.c)
and [geni-se.h](https://github.com/torvalds/linux/blob/v6.15/include/linux/soc/qcom/geni-se.h).
These upstream implementations are copyright The Linux Foundation and their
listed contributors, licensed GPL-2.0. Windows DDI usage was checked against
[Microsoft's SkeletonI2C sample](https://github.com/microsoft/Windows-driver-samples/tree/main/spb/SkeletonI2C)
and the SpbCx documentation. No Linux runtime is linked into this Windows SYS.

```powershell
./Resources/Scripts/build_geni_i2c.ps1
```

The build validates package files/ARM64 PE type and records source revision and
SHA256 hashes. A successful build is not authorization to enable the handoff
gates or install this driver as a root device. The real ACPI resources and
validated power contract remain necessary.
