# Native V60 GPI transport

The new experimental translated Windows IOMMU profile is documented in
[TOUCH-IOMMU.md](../../../Platforms/LG/timelmPkg/Experimental/TOUCH-IOMMU.md).
It has a separate ACPI contract and remains disabled. The BYPASS description
below describes the original profile, not the new translated backend.

The SPB host now contains a source GPI backend, not a renamed Qualcomm binary.
It is an experimental integration, not yet a working-on-phone claim. FIFO and
GPI share the board clock/GPIO lifecycle, but use separate transport state.

NativeGpiEnabled=1 additionally requires NativeBoardInitEnabled=1 and the exact
TouchGpiWindows.asl revision TBCF=0x54420201. Both flags and ACPI _STA are off
by default. This profile maps GPI1 A00000/70000, uses GPII0 with the vendor EE
offset 6000, reserves raw GSIV311, and reads the SMMU register page read-only.
It does not configure/claim the BSP's QCOM2593 device or reuse Recovery IOVAs.

## Integrated request path

SPB Execute pre-maps complete MDL chains, then the selected GPI backend creates
CONFIG0/GO/DMA TREs. TX and RX use 64-entry rings, with one 256-entry event ring.
The first transfer sends the fixed 100 kHz configuration from a verified 19.2
MHz source. Each write/read sequence retains repeated START with STOP_STRETCH
and one shared 50 ms deadline. RX doorbell precedes TX GO publication.

Each completion must match its expected channel, exact descriptor DMA address,
event type/code, zero error status and exact byte count. RX data is copied to
the SPB caller only after both TX GO and RX DMA completion. Wrap, reversed event
arrival, malformed events, cancellation and stalled completion are tested.
The passive GPI interrupt handles data/error notification; control commands and
producer-pointer progress remain bounded polling for this bring-up version.

## DMA policy and lifecycle

IoGetDmaAdapter/AllocateCommonBuffer supply a single uncached 8 KB common buffer;
DMA addresses always come from the adapter. The initial profile supports only
a verified firmware BYPASS mapping for stream 56, with matching physical backing
for the adapter's logical common-buffer address. It refuses an unknown, faulting,
disabled-global or translated SMMU context. A translated configuration requires
a real Windows IOMMU/domain integration, not a registry switch or a cast from
virtual/Recovery addresses. No SMMU register is written.

Clock/engine checks and GPI/DMA prerequisites run before acquiring touch output
GPIOs. Channel startup refuses any already-allocated/live GPII0 instance. It
requires command-completion status plus the expected state, rather than inferring
success from an initially-zero context. Stop/reset/deallocate must confirm both
channels and event ring are quiesced before releasing the DMA buffer/adapter.

If quiescence cannot be confirmed, the explicit non-WDF-owned buffer and adapter
are retained until reboot, interrupts detach and board clock/power restoration
is skipped. DMA was never pointed at a stack, request or executable buffer. The
retained/unsafe state is recorded; restart is refused. This deliberate failure
retention is a bring-up limit, not a production recovery strategy.

No runtime idle is enabled. Suspend/resume, shared SE locking, other
GPI instances/targets and a production asynchronous transfer engine are not
validated. The translated backend is now implemented as an experimental source
path; Windows IOMMU hardware operation is not validated. Hardware tests must establish firmware ownership/fabric access,
the actual SMMU mapping, I2C ID read, GPIO interrupts and usable Windows HID.

## Tests

gpi_test.c exercises every length 1..256, repeated START, multiple wraps of TX,
RX and event rings, >4 GB addresses, reversed completions, invalid/duplicate
descriptor metadata, partial reads, timeouts, cancellation, active-instance
refusal, missing command acknowledgement and failed DMA teardown. SMMU tests
reject unknown/translated/faulting and overlapping conflicting stream matches.
ASan/UBSan pass locally. ARM64 WDK host/client and GPIO builds, portable tests
and both disabled ACPI profiles passed at ad2aa09 in
[Actions run 39239450021](https://github.com/rofikkerneldev/test_mu-timelm/actions/runs/39239450021).
That run also checks touch scan activation after Windows interrupt readiness.
It does not establish Windows hardware operation or the phone's DMA mapping.

The implementation uses register formats/sequencing from the GPL-2.0 Linux
Foundation/Linaro GPI drivers, with attribution retained in geni_gpi.h. The
Windows adapter uses public Microsoft DMA and KMDF interfaces. No proprietary
driver ABI is guessed or proprietary SYS file redistributed by this backend.
