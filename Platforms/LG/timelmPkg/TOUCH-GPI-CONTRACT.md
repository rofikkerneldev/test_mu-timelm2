# V60 touch GPI transport contract

The Windows FIFO host is not a demonstrated transport for the phone. Recovery
controlled product reads increment GPI1 GPII0 GSIV 311 without a GENI GSIV 390
interrupt. The vendor I2C source selects GSI_ONLY when FIFO is disabled. Treat
GPI as the required observed path until a Mu/Windows snapshot establishes a
different configuration. Do not overwrite GENI_IF_FIFO_DISABLE_RO.

| Board item | Recovery observation |
| --- | --- |
| Touch serial engine | QUPv3 wrapper1, local SE5, MMIO A94000/4000 |
| DMA provider | GPI1 A00000/70000 |
| TX/RX DT tuples | provider, channel 0/1, SE5, protocol3, ring64, flags0 |
| Live assigned GPI instance | GPII0, SPI279 +32 = GSIV311 |
| EE register offset | 6000 |
| Available instance mask | 3F; maximum count A |
| SMMU stream ID | 56, mask0 |
| Vendor DMA IOVA pool | 100000/100000 |
| Touch product transaction | write 26 44, repeated START, read8, result B3W68TIM |
| Report transaction | write 26 00, repeated START, read156 |

DMA DT tuples identify SE5; this is not Windows GPII5. The live interrupt proves
GPII0 assignment in this Recovery run. An IOVA is not a CPU physical address.
Ring addresses must come from an OS DMA mapping with a verified matching stream
and address width; never reuse Recovery IOVAs or cast allocated pointers.

## Existing BSP route

The public WOA-Project/windows_silicon_qcom_kona BSP revision
22221a09e02cb7054792427af60299b1c34d3c3e supplies qcgpi8250.inf with QUP1's
GPII0=311 mapping. It targets QCOM2593, KMDF1.25 and service qcGPI. The qci2c
INF defines OpMode=1 for GPI and QUPType=1 for wrapper1, but has only instance
2/5/7/8/10 entries and no entry14. Its ACPI match QCOM2511 differs from alioth's
QCOM2510 I2C nodes; alioth's QCOM2593 node is sensor-related. A filename or
interrupt match does not prove the private interface/resource ABI.

The inspected qcgpi8250.sys has original filename qcgpi8180.sys, version
1.0.2100.0000, valid embedded signature on this PC, SHA256
9f931f50b3c0b49b527713d18a71edd098208141b3cff5ce0df162cdbed2b94f.
The original filename alone does not prove incompatibility; it reinforces the
need to establish the actual interface/resource contract rather than use the
renamed file as compatibility evidence.

Before using this route, establish the provider's real ACPI memory/resource
ordering, driver-to-driver interface and SE14 registration, clock dependencies,
SCM ownership and DMA/SMMU contract. Preserve signed upstream files; editing an
INF invalidates its catalog. Do not inject a guessed node or substitute the
new GPIO driver's ID for the BSP GPIO dependency.

## Source transport route

A source GPI adapter needs two channels and an event ring, CONFIG0 and GO TREs
for 100 kHz, repeated START for the command/read pair, mapped TX/RX buffers,
completion validation, cancellation, bounded stop/reset and safe ring teardown.
It must validate event type, channel, descriptor pointer, transferred length
and hardware errors before copying any DMA buffer into an SPB response. A timeout
must quiesce DMA before freeing mappings. A valid HID decoder cannot supply any
of these requirements.

The project now integrates this source path in geni_gpi.c/gpi_windows.c and the
SPB Execute/D0/release callbacks. See [GPI implementation and limits](../../../GPLDrivers/Windows/KonaGeniI2c/GPI.md).
The initial DMA policy supports verified firmware BYPASS only; translated SMMU
operation still needs Windows IOMMU/domain support. Do not describe source
integration, clock/GPIO builds or Recovery packets as a completed touchscreen fix.

## Evidence and references

Raw local captures: recovery-touch-controlled-read.txt,
recovery-touch-swipe-packets.txt and recovery-touch-decoded.jsonl in diagnostics/.
Recovery config has neither DEBUG_FS nor DEVMEM. The collection script uses
the existing kernel I2C adapter without resetting/unbinding its touch driver.

- [LG vendor I2C/GSI path](https://github.com/rofikkerneldev/lgv60nextgen_rofikkernel/blob/lineage-23.0/drivers/i2c/busses/i2c-qcom-geni.c)
- [Linux v6.15 GPI DMA implementation](https://github.com/torvalds/linux/blob/v6.15/drivers/dma/qcom/gpi.c)
- [Pinned BSP GPI INF](https://github.com/WOA-Project/windows_silicon_qcom_kona/blob/22221a09e02cb7054792427af60299b1c34d3c3e/Drivers/SOC/Buses/GPI/qcgpi8250.inf)
